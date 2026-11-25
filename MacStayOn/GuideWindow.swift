import AppKit
import SwiftUI

enum GuidePage: Int, CaseIterable {
    case welcome, turnOn, glow, shortcut, updates
}

final class GuideModel: ObservableObject {
    enum Mode: Equatable {
        case guide
        case updated(version: String, notes: [String], stayAwakeWasOn: Bool)
    }

    @Published var mode: Mode = .guide
    @Published var page: GuidePage = .welcome
    @Published var moveError: String?
}

/// The in-app walkthrough: shown on first launch, as a "what's new" screen
/// after an update, and any time from the ? button in the menu.
final class GuideWindowController {
    private let model = GuideModel()
    private let sleepManager: SleepAssertionManager
    private let keyboardShortcut: KeyboardShortcutController
    private let launchAtLogin: LaunchAtLoginController
    private let checkForUpdates: () -> Void
    private var window: NSWindow?

    init(
        sleepManager: SleepAssertionManager,
        keyboardShortcut: KeyboardShortcutController,
        launchAtLogin: LaunchAtLoginController,
        checkForUpdates: @escaping () -> Void
    ) {
        self.sleepManager = sleepManager
        self.keyboardShortcut = keyboardShortcut
        self.launchAtLogin = launchAtLogin
        self.checkForUpdates = checkForUpdates
    }

    func show(_ guide: LaunchGuide) {
        switch guide {
        case .none:
            return
        case .welcome:
            showGuide(at: .welcome)
        case .resumeAfterMove:
            // Moved into Applications and relaunched: pick up at the next step.
            showGuide(at: .turnOn)
        case let .updated(from, to, wasOn):
            model.mode = .updated(version: to, notes: WhatsNew.notes(since: from), stayAwakeWasOn: wasOn)
            present()
        }
    }

    func showGuide(at page: GuidePage = .welcome) {
        model.mode = .guide
        model.page = page
        model.moveError = nil
        present()
    }

    private func present() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: GuideLayout.width, height: GuideLayout.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MacStayOn Guide"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GuideView(
            model: model,
            sleepManager: sleepManager,
            keyboardShortcut: keyboardShortcut,
            launchAtLogin: launchAtLogin,
            actions: GuideActions(
                moveToApplications: { [weak self] in self?.moveToApplications() },
                checkForUpdates: checkForUpdates,
                close: { [weak window] in window?.close() }
            )
        ))
        return window
    }

    private func moveToApplications() {
        let original = InstallLocation.originalURL(of: Bundle.main.bundleURL)
        do {
            let destination = try AppMover().moveIntoApplications(original)
            UserDefaults.standard.set(true, forKey: LaunchGuideDecider.resumeAfterMoveKey)
            AppMover.relaunch(at: destination)
        } catch {
            model.moveError = "Couldn't move it automatically. In Finder, drag MacStayOn into Applications, then open it from there."
            NSWorkspace.shared.activateFileViewerSelecting([original])
        }
    }
}

struct GuideActions {
    let moveToApplications: () -> Void
    let checkForUpdates: () -> Void
    let close: () -> Void
}

private enum GuideLayout {
    static let width: CGFloat = 620
    static let height: CGFloat = 540
    static let artHeight: CGFloat = 180
}

private enum GuidePalette {
    static let orange = Color(red: 0.96, green: 0.55, blue: 0.18)
    static let green = Color(red: 0.2, green: 0.68, blue: 0.38)
    static let ink = Color(red: 0.07, green: 0.09, blue: 0.14)
    static let art = LinearGradient(
        colors: [Color(red: 0.09, green: 0.11, blue: 0.18), Color(red: 0.16, green: 0.19, blue: 0.29)],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Views

private struct GuideView: View {
    @ObservedObject var model: GuideModel
    @ObservedObject var sleepManager: SleepAssertionManager
    @ObservedObject var keyboardShortcut: KeyboardShortcutController
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    let actions: GuideActions

    var body: some View {
        Group {
            switch model.mode {
            case .guide:
                pages
            case let .updated(version, notes, wasOn):
                updatedScreen(version: version, notes: notes, stayAwakeWasOn: wasOn)
            }
        }
        .frame(width: GuideLayout.width, height: GuideLayout.height)
    }

    // MARK: Walkthrough

    private var pages: some View {
        VStack(spacing: 0) {
            art(for: model.page)
                .frame(maxWidth: .infinity)
                .frame(height: GuideLayout.artHeight)
                .background(GuidePalette.art)
            VStack(alignment: .leading, spacing: 14) {
                Text(title(for: model.page))
                    .font(.system(size: 22, weight: .bold))
                content(for: model.page)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(GuidePage.allCases, id: \.self) { page in
                    Circle()
                        .fill(page == model.page ? GuidePalette.orange : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .onTapGesture { model.page = page }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(model.page.rawValue + 1) of \(GuidePage.allCases.count)")
            Spacer()
            if model.page != .welcome {
                Button("Back") { step(-1) }
                    .controlSize(.large)
            }
            Button(isLastPage ? "Done" : "Next") {
                if isLastPage { actions.close() } else { step(1) }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .tint(GuidePalette.orange)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var isLastPage: Bool { model.page == GuidePage.allCases.last }

    private func step(_ delta: Int) {
        if let page = GuidePage(rawValue: model.page.rawValue + delta) {
            model.page = page
        }
    }

    private func title(for page: GuidePage) -> String {
        switch page {
        case .welcome: return "Welcome to MacStayOn"
        case .turnOn: return "Turn Stay Awake on"
        case .glow: return "On, with a warm glow"
        case .shortcut: return "Keyboard shortcut"
        case .updates: return "Staying up to date"
        }
    }

    @ViewBuilder
    private func content(for page: GuidePage) -> some View {
        switch page {
        case .welcome: welcomeContent
        case .turnOn: turnOnContent
        case .glow: glowContent
        case .shortcut: shortcutContent
        case .updates: updatesContent
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("MacStayOn keeps your Mac awake with the lid open or closed, so agents, builds and downloads keep running. Turn it off and normal sleep comes back.")
            InfoRow(symbol: "moon.zzz.fill", tint: .secondary,
                    text: "**It lives in your menu bar.** Look for the moon near the clock. There's no Dock icon or window.")
            installRow
        }
    }

    @ViewBuilder
    private var installRow: some View {
        let appURL = Bundle.main.bundleURL
        if InstallLocation.isInApplicationsFolder(appURL) {
            InfoRow(symbol: "checkmark.circle.fill", tint: GuidePalette.green,
                    text: "**Installed in Applications.** Updates will install right here.")
        } else {
            let folder = InstallLocation.folderName(of: InstallLocation.originalURL(of: appURL))
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(symbol: "exclamationmark.triangle.fill", tint: GuidePalette.orange,
                        text: "**Running from \(folder).** Move MacStayOn to Applications so updates work and you keep just one copy.")
                HStack(spacing: 10) {
                    Button("Move to Applications") { actions.moveToApplications() }
                        .buttonStyle(.borderedProminent)
                        .tint(GuidePalette.orange)
                        .disabled(sleepManager.isEnabled)
                    if sleepManager.isEnabled {
                        Text("Turn Stay Awake off first.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("MacStayOn reopens from Applications.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 30)
                if let error = model.moveError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(GuidePalette.orange)
                        .padding(.leading, 30)
                }
            }
        }
    }

    private var turnOnContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepRow(number: 1, text: "Click the **moon** in the menu bar.")
            StepRow(number: 2, text: "Click **Stay Awake**, read the short heat warning, then click **Turn On**.")
            StepRow(number: 3, text: "Approve with **Touch ID** (or your password). Each Turn On asks once.")
            Prose("Cancel at any step and MacStayOn stays Off. Nothing changes.")
                .foregroundStyle(.secondary)
        }
    }

    private var glowContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Prose("While Stay Awake is on, the moon becomes a **sun**, and a warm glow with a pull chain hangs from the menu bar.")
            Text("To turn off (no password needed):")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                Chip(symbol: "hand.point.up.left.fill", text: "Click the **pull knob**")
                Chip(symbol: "moon.zzz.fill", text: "**Restore** in the menu")
                Chip(symbol: "keyboard", text: "Hold **← → ↑ ↓ + Space**")
                Chip(symbol: "power", text: "**Quit** MacStayOn")
            }
            InfoRow(symbol: "thermometer.medium", tint: GuidePalette.orange,
                    text: "Closing the lid? Keep the Mac out of bags and blankets. **Heat & batt.** turns Stay Awake off at low battery or serious heat.")
        }
    }

    private var shortcutContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("Hold **all four arrow keys and Space** together, from any app. Off is instant; On asks for Touch ID.")
            if keyboardShortcut.needsPermission {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(symbol: "exclamationmark.triangle.fill", tint: GuidePalette.orange,
                            text: "**Needs Input Monitoring permission.** MacStayOn only listens for this one combination; your typing still goes to your apps.")
                    Button("Open Input Monitoring") { keyboardShortcut.openPermissionSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(GuidePalette.orange)
                        .padding(.leading, 30)
                    Prose("Switch **MacStayOn** on in the list. Not listed? Click **+**, choose **Applications → MacStayOn**, then switch it on. If asked, click **Quit & Reopen**.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                }
            } else {
                InfoRow(symbol: "checkmark.circle.fill", tint: GuidePalette.green,
                        text: "**Shortcut is ready.** Try it any time.")
            }
        }
        .onAppear { keyboardShortcut.refreshPermission() }
    }

    private var updatesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepRow(number: 1, text: "MacStayOn checks **once a day** and never installs without asking.")
            StepRow(number: 2, text: "When one is ready, **Updates** in the menu turns into an orange **Update** button. Click it, then **Install Update**.")
            StepRow(number: 3, text: "Updating restarts MacStayOn, which turns Stay Awake off. Turn it back on afterward.")
            HStack(spacing: 14) {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    Text("Open MacStayOn when I log in")
                        .font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Button("Check for Updates Now") { actions.checkForUpdates() }
            }
            .padding(.top, 4)
        }
        .onAppear { launchAtLogin.refresh() }
    }

    // MARK: After an update

    private func updatedScreen(version: String, notes: [String], stayAwakeWasOn: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(GuidePalette.orange)
                    Text(version)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: GuideLayout.artHeight)
            // Same as the walkthrough: the art runs up under the transparent title bar.
            .background(GuidePalette.art)
            VStack(alignment: .leading, spacing: 14) {
                Text("MacStayOn is updated to \(version)")
                    .font(.system(size: 22, weight: .bold))
                if stayAwakeWasOn {
                    InfoRow(symbol: "moon.zzz.fill", tint: GuidePalette.orange,
                            text: "**Stay Awake was turned off for the update.** Turn it back on from the menu bar when you need it.")
                }
                if !notes.isEmpty {
                    Text("What's new")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(notes, id: \.self) { note in
                        InfoRow(symbol: "star.fill", tint: GuidePalette.orange, text: note)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                Spacer()
                Button("Open the Guide") {
                    model.mode = .guide
                    model.page = .welcome
                }
                .controlSize(.large)
                Button("Done") { actions.close() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .tint(GuidePalette.orange)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    // MARK: Art

    @ViewBuilder
    private func art(for page: GuidePage) -> some View {
        switch page {
        case .welcome: MenuBarArt()
        case .turnOn: TurnOnArt()
        case .glow: GlowArt()
        case .shortcut: KeysArt()
        case .updates: UpdateArt()
        }
    }
}

// MARK: - Building blocks

private struct Prose: View {
    let markdown: String
    init(_ markdown: String) { self.markdown = markdown }
    var body: some View {
        Text(.init(markdown))
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InfoRow: View {
    let symbol: String
    let tint: Color
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            Prose(text)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(GuidePalette.orange))
            Prose(text)
        }
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GuidePalette.orange)
                .frame(width: 16)
            Text(.init(text))
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1)))
    }
}

// MARK: - Illustrations

/// A menu bar with the MacStayOn moon picked out.
private struct MenuBarArt: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                ZStack {
                    Circle()
                        .stroke(GuidePalette.orange, lineWidth: 2)
                        .frame(width: 30, height: 30)
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.white)
                }
                Text("Wed 9:41")
                    .font(.system(size: 13, weight: .medium))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .frame(width: 420, height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                Text("MacStayOn lives here")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GuidePalette.orange)
            .offset(x: 70)
        }
    }
}

/// The MacStayOn bar with Stay Awake, then Touch ID.
private struct TurnOnArt: View {
    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(red: 0.22, green: 0.27, blue: 0.38)).frame(width: 30, height: 30)
                    Image(systemName: "moon.zzz.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacStayOn").font(.system(size: 13, weight: .semibold))
                    Text("OFF").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text("Stay Awake").fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(GuidePalette.orange))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .environment(\.colorScheme, .light)
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Image(systemName: "touchid")
                .font(.system(size: 46))
                .foregroundStyle(Color(red: 0.98, green: 0.38, blue: 0.42))
        }
    }
}

/// The real glow and pull chain, lit.
private struct GlowArt: View {
    @StateObject private var model: LampModel = {
        let model = LampModel()
        model.opacity = 1
        model.lit = 1
        return model
    }()

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.black.opacity(0.35)).frame(height: 14)
            LampView(model: model, geometry: LampGeometry(topInset: 14))
                .scaleEffect(1.3, anchor: .top)
                // Full width before clipping, or the enlarged glow is cut off at the sides.
                .frame(maxWidth: .infinity)
                .frame(height: GuideLayout.artHeight, alignment: .top)
                .clipped()
            HStack {
                Spacer()
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(GuidePalette.orange)
                    .padding(.trailing, 14)
                    .padding(.top, 2)
            }
        }
    }
}

/// ← → ↑ ↓ + Space as keycaps.
private struct KeysArt: View {
    var body: some View {
        HStack(spacing: 22) {
            VStack(spacing: 4) {
                Keycap(label: "↑")
                HStack(spacing: 4) {
                    Keycap(label: "←")
                    Keycap(label: "↓")
                    Keycap(label: "→")
                }
            }
            Text("+")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            Keycap(label: "space", width: 190)
        }
    }
}

private struct Keycap: View {
    let label: String
    var width: CGFloat = 44
    var body: some View {
        Text(label)
            .font(.system(size: label.count > 1 ? 13 : 18, weight: .semibold))
            .foregroundStyle(GuidePalette.ink)
            .frame(width: width, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: 3)
            )
    }
}

/// The orange Update button, then Install and Relaunch.
private struct UpdateArt: View {
    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update").fontWeight(.semibold)
            }
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(GuidePalette.orange))
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                Text("Install and Relaunch").fontWeight(.medium)
            }
            .font(.system(size: 13))
            .foregroundStyle(GuidePalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white))
        }
    }
}
