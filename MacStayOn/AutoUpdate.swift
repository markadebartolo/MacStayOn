import Foundation

/// Automatic updates download in the background (Sparkle). Installing one
/// restarts MacStayOn, and quitting turns Stay Awake off — so a downloaded
/// update waits here until that can't interrupt anything: Stay Awake is off
/// and no Turn On is in progress. Then it installs, and MacStayOn reopens
/// showing what's new.
final class UpdateInstallGate {
    /// Quiet time after things go idle before installing, so an Off
    /// confirmation finishes and a quick Turn On again isn't cut off.
    static let defaultGracePeriod: TimeInterval = 10

    private let isBusy: () -> Bool
    private let gracePeriod: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var pendingInstall: (() -> Void)?
    /// Bumped on every state change so only the latest scheduled check can install.
    private var attempt = 0

    var hasPendingUpdate: Bool { pendingInstall != nil }

    init(
        gracePeriod: TimeInterval = UpdateInstallGate.defaultGracePeriod,
        isBusy: @escaping () -> Bool,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.gracePeriod = gracePeriod
        self.isBusy = isBusy
        self.schedule = schedule
    }

    /// Sparkle finished downloading; `install` installs it and relaunches the app.
    func updateReady(install: @escaping () -> Void) {
        pendingInstall = install
        stateChanged()
    }

    /// Call whenever Stay Awake or a Turn On in progress changes.
    func stateChanged() {
        attempt &+= 1
        let thisAttempt = attempt
        guard pendingInstall != nil, !isBusy() else { return }
        schedule(gracePeriod) { [weak self] in
            guard let self, self.attempt == thisAttempt, !self.isBusy(),
                  let install = self.pendingInstall else { return }
            self.pendingInstall = nil
            install()
        }
    }
}
