import AppKit
import ServiceManagement
import SwiftUI

enum GuidePage: Int, CaseIterable {
    case welcome, turnOn, glow, permissions, updates
}

final class GuideModel: ObservableObject {
    enum Mode: Equatable {
        case guide
        case updated(version: String, notes: [String], stayAwakeWasOn: Bool)
    }

    @Published var mode: Mode = .guide
    @Published var page: GuidePage = .welcome
    @Published var moveError: String?
    @Published var safetyNet: SafetyNetPermission.Status = .notInstalled
}

/// The in-app walkthrough: shown on first launch, as a "what's new" screen
/// after an update, and any time from the ? button in the menu.
final class GuideWindowController {
    private let model = GuideModel()
    private let sleepManager: SleepAssertionManager
    private let keyboardShortcut: KeyboardShortcutController
    private let launchAtLogin: LaunchAtLoginController
    private let checkForUpdates: () -> Void
    let notifications: NotificationPermission
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(
        sleepManager: SleepAssertionManager,
        keyboardShortcut: KeyboardShortcutController,
        launchAtLogin: LaunchAtLoginController,
        notifications: NotificationPermission = NotificationPermission(),
        checkForUpdates: @escaping () -> Void
    ) {
        self.sleepManager = sleepManager
        self.keyboardShortcut = keyboardShortcut
        self.launchAtLogin = launchAtLogin
        self.notifications = notifications
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
        // Closing the guide without answering the notifications row: ask once,
        // now that the guide has explained why (never on top of the guide).
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.notifications.requestIfNotAsked()
        }
        window.contentView = NSHostingView(rootView: GuideView(
            model: model,
            sleepManager: sleepManager,
            keyboardShortcut: keyboardShortcut,
            launchAtLogin: launchAtLogin,
            notifications: notifications,
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
    static let height: CGFloat = 600
    static let artHeight: CGFloat = 165
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
    @ObservedObject var notifications: NotificationPermission
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
        case .glow: return "A glow confirms it"
        case .permissions: return "Permissions"
        case .updates: return "Staying up to date"
        }
    }

    @ViewBuilder
    private func content(for page: GuidePage) -> some View {
        switch page {
        case .welcome: welcomeContent
        case .turnOn: turnOnContent
        case .glow: glowContent
        case .permissions: permissionsContent
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
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("From the menu")
            StepRow(number: 1, text: "Click the **moon** in the menu bar.")
            StepRow(number: 2, text: "Click **Stay Awake**, read the short heat warning, then click **Turn On**.")
            StepRow(number: 3, text: "Approve with **Touch ID** (or your password). Each Turn On asks once.")
            SectionLabel("Or with the keyboard, from any app")
                .padding(.top, 8)
            HStack(alignment: .center, spacing: 14) {
                InlineShortcutKeys()
                Prose("Hold all five together, then approve with **Touch ID**. Hold them again to turn off, instantly.")
            }
            shortcutStatus
            Prose("Cancel at any step and MacStayOn stays Off. Nothing changes.")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .onAppear { keyboardShortcut.refreshPermission() }
    }

    @ViewBuilder
    private var shortcutStatus: some View {
        if keyboardShortcut.needsPermission {
            HStack(spacing: 10) {
                InfoRow(symbol: "exclamationmark.triangle.fill", tint: GuidePalette.orange,
                        text: "The shortcut needs **Input Monitoring** permission.")
                ActionButton("Set Up") { model.page = .permissions }
            }
        } else {
            InfoRow(symbol: "checkmark.circle.fill", tint: GuidePalette.green,
                    text: "**Shortcut is ready.** If nothing happens, your keyboard may not register five keys at once.")
        }
    }

    private var glowContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Prose("When Stay Awake turns on, a pull chain drops from under the menu bar, gets a tug, and a warm glow flickers on, then it tucks away. Turning off shows the tug and the glow going out. It's a quick sign that it worked, handy with the keyboard shortcut.")
            Prose("The rest of the time, the menu bar icon shows the state: **sun** is on, **moon** is off.")
                .foregroundStyle(.secondary)
            Text("To turn off (no password needed):")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                Chip(symbol: "moon.zzz.fill", text: "**Restore** in the menu")
                Chip(symbol: "keyboard", text: "Hold **← → ↑ ↓ + Space**")
                Chip(symbol: "power", text: "**Quit** MacStayOn")
            }
            InfoRow(symbol: "thermometer.medium", tint: GuidePalette.orange,
                    text: "Closing the lid? Keep the Mac out of bags and blankets. **Heat & batt.** turns Stay Awake off at low battery or serious heat.")
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            Prose("Everything MacStayOn may ask for, and why. Status updates as you change settings.")
                .foregroundStyle(.secondary)
            PermissionRow(symbol: "touchid", title: "Administrator approval",
                          detail: "Asked each time you turn on, with Touch ID or your password. It's what lets the Mac stay awake with the lid closed.") {
                Text("Each Turn On")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            PermissionRow(symbol: "keyboard", title: "Input Monitoring",
                          detail: "Lets **← → ↑ ↓ + Space** work from any app. MacStayOn only listens for that combination.") {
                if keyboardShortcut.needsPermission {
                    ActionButton("Open Settings") { keyboardShortcut.openPermissionSettings() }
                } else {
                    StatusBadge(text: "Allowed")
                }
            }
            PermissionRow(symbol: "bell.badge", title: "Notifications",
                          detail: "A heads-up when an update is ready.") {
                switch notifications.status {
                case .allowed:
                    StatusBadge(text: "Allowed")
                case .notAsked:
                    ActionButton("Allow") { notifications.request() }
                case .denied:
                    ActionButton("Open Settings") { notifications.openSettings() }
                case .unknown, .unavailable:
                    Text("—").foregroundStyle(.secondary)
                }
            }
            PermissionRow(symbol: "lock.shield", title: "Background safety net",
                          detail: "Runs only while Stay Awake is on, and restores normal sleep if MacStayOn is force-quit. If macOS says **Background Items Added**, keep MacStayOn allowed.") {
                switch model.safetyNet {
                case .allowed:
                    StatusBadge(text: "Allowed")
                case .blocked:
                    ActionButton("Turn On in Settings") { SafetyNetPermission.openLoginItemsSettings() }
                case .notInstalled:
                    Text("Added when on")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            PermissionRow(symbol: "power", title: "Open at login (optional)",
                          detail: "Starts MacStayOn when you log in. Stay Awake still starts Off.") {
                if launchAtLogin.needsApproval {
                    ActionButton("Approve") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
        .onAppear(perform: refreshPermissions)
        // Coming back from System Settings: show what changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        keyboardShortcut.refreshPermission()
        notifications.refresh()
        launchAtLogin.refresh()
        model.safetyNet = SafetyNetPermission.status()
    }

    private var updatesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepRow(number: 1, text: "MacStayOn checks **once a day** and never installs without asking.")
            StepRow(number: 2, text: "When one is ready, **Updates** in the menu turns into an orange **Update** button (and you get a notification, if allowed). Click it, then **Install Update**.")
            StepRow(number: 3, text: "Updating restarts MacStayOn, which turns Stay Awake off. Turn it back on afterward. Your settings and permissions carry over.")
            HStack {
                Spacer()
                Button("Check for Updates Now") { actions.checkForUpdates() }
            }
            .padding(.top, 4)
        }
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
        case .permissions: PermissionsArt()
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

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
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

private struct PermissionRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GuidePalette.orange)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GuidePalette.orange.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(.init(detail))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            trailing()
                .frame(minWidth: 96, alignment: .trailing)
        }
    }
}

private struct StatusBadge: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GuidePalette.green)
    }
}

private struct ActionButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(GuidePalette.orange)
            .controlSize(.small)
    }
}

// MARK: - Illustrations

/// The permissions as a row of checked tiles.
private struct PermissionsArt: View {
    var body: some View {
        HStack(spacing: 16) {
            ForEach(["touchid", "keyboard", "bell.badge", "lock.shield", "power"], id: \.self) { symbol in
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 58, height: 58)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white, GuidePalette.green)
                        .offset(x: 5, y: 5)
                }
            }
        }
    }
}

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

/// The real on/off confirmation, caught while lit.
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
/// ← → ↑ ↓ + Space as small keycaps, for the light content area.
private struct InlineShortcutKeys: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["←", "→", "↑", "↓"], id: \.self) { Keycap(label: $0, width: 26, height: 26, onLight: true) }
            Text("+")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            Keycap(label: "space", width: 66, height: 26, onLight: true)
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Left, right, up and down arrows plus Space")
    }
}

private struct Keycap: View {
    let label: String
    var width: CGFloat = 44
    var height: CGFloat = 44
    /// On a light background: add an outline and a softer edge so the key reads.
    var onLight = false
    var body: some View {
        Text(label)
            .font(.system(size: label.count > 1 ? height * 0.36 : height * 0.42, weight: .semibold))
            .foregroundStyle(GuidePalette.ink)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: onLight ? 0.9 : 0.84)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(onLight ? 0.25 : 0.45), radius: 0, x: 0, y: onLight ? 2 : 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .stroke(Color.black.opacity(onLight ? 0.15 : 0), lineWidth: 0.5)
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
