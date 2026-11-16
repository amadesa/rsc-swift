import UserNotifications
import WatchKit

/// Keeps the game running while the wrist is down or another app is open.
/// watchOS normally suspends an app moments after the screen turns off, which
/// stops the relay polls and drops the connection. An extended runtime
/// session (the "physical-therapy" background mode in Watch-Info.plist) lets
/// it keep running for up to an hour at a time. A session can only be started
/// while the app is on screen, so a new one starts whenever it comes back.
final class KeepAlive: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    static let shared = KeepAlive()

    private var session: WKExtendedRuntimeSession?

    /// When the running session ends, for showing how long alerts last.
    @Published private(set) var expiresAt: Date?

    /// Whether to warn that the app is about to be suspended: watching the
    /// iPhone or logged in on the watch, when alerts would stop.
    var isNeeded: () -> Bool = { false }

    /// Starts a session unless one is already running or starting.
    func start() {
        // a session stays .notStarted for a moment after start(), and
        // replacing it then would invalidate it
        if let session = session, session.state != .invalid {
            return
        }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async {
            self.expiresAt = extendedRuntimeSession.expirationDate
        }
    }

    /// Sent shortly before the hour is up.
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.warnAlertsStopping() }
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?
    ) {
        DispatchQueue.main.async {
            guard self.session === extendedRuntimeSession else { return }
            self.session = nil
            self.expiresAt = nil

            // expiry was already warned about; the app being opened again
            // (the only way to start a new session) needs no warning
            if reason != .expired && reason != .none && reason != .suppressedBySystem {
                self.warnAlertsStopping()
            }
        }
    }

    /// watchOS suspends the app once the session ends, so the game and the
    /// iPhone's alerts stop until it's opened again.
    private func warnAlertsStopping() {
        guard isNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "RSC alerts paused"
        content.body = "watchOS only lets RSC run in the background for an hour. Open RSC on the watch to keep the alerts coming."
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "keep_alive", content: content, trigger: nil))
    }
}
