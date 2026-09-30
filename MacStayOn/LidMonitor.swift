import Foundation

/// Observes MacBook clamshell (lid) open/close via Darwin notify.
final class LidMonitor {
    /// Called with `true` when the lid closes, `false` when it opens.
    var onClamshellChange: ((Bool) -> Void)?

    private var token: Int32 = 0
    private var registered = false
    private var lastClosed: Bool?

    func start() {
        stop()
        let name = "com.apple.system.powermanagement.clamshellstate"
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { [weak self] t in
            guard let self else { return }
            var state: UInt64 = 0
            notify_get_state(t, &state)
            // Non-zero ⇒ clamshell closed (observed on Apple Silicon / Intel MacBooks).
            let closed = state != 0
            let previous = self.lastClosed
            self.lastClosed = closed
            guard let previous else { return } // ignore initial seed
            if previous != closed {
                self.onClamshellChange?(closed)
            }
        }
        registered = status == NOTIFY_STATUS_OK
        if registered {
            var state: UInt64 = 0
            notify_get_state(token, &state)
            lastClosed = state != 0
        }
    }

    func stop() {
        if registered {
            notify_cancel(token)
            registered = false
        }
        token = 0
        lastClosed = nil
    }

    deinit {
        stop()
    }
}
