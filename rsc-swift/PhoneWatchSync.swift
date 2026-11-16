import Foundation
import UIKit
import WatchConnectivity

/// Sends the watch app what it needs to play: the relay settings from
/// Settings > RSC, and the game's options.ini (without the password),
/// worlds.cfg and combat-styles.cfg. Uses WatchConnectivity's application
/// context, which Apple encrypts and delivers whenever the watch app next
/// runs. The iPhone is the source of truth, except for the watch's own
/// display settings, which can also be changed on the watch
/// (WatchSync.keepingWatchSettings).
///
/// The saved accounts (AccountStore) go only in messages to the watch app
/// while it's open, so their passwords aren't stored anywhere on the way.
///
/// It also sends the watch's relay requests on when the watch can't reach
/// the relay itself (RelayRoute's route through the iPhone).
final class PhoneWatchSync: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchSync()

    /// files from the config directory that the watch gets a copy of
    static let syncedFiles = ["options.ini", "worlds.cfg", "combat-styles.cfg"]

    private var configDirectory: URL?

    /// the last status sent to the watch, so only changes are sent
    private var sentStatus: [String: Any]?

    /// alerts the watch couldn't be sent, handed over when it next asks
    private var pendingAlerts: [(sent: Date, message: [String: Any])] = []

    /// Called at launch (AppDelegate), so the watch's messages are answered
    /// even when iOS starts the app in the background for one.
    func activate() {
        guard WCSession.isSupported(), !isActivated else { return }
        isActivated = true

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private var isActivated = false

    func start(configDirectory: URL) {
        self.configDirectory = configDirectory
        activate()
        push()
    }

    /// Sends the current settings, e.g. after options may have changed.
    func push() {
        guard WCSession.isSupported(), let configDirectory = configDirectory else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled
        else { return }

        let defaults = UserDefaults.standard
        var context: [String: Any] = [
            "relay_url": defaults.string(forKey: "relay_url") ?? "",
            // the watch's own token when pairing made one (RelayController)
            "relay_token": defaults.string(forKey: "relay_watch_token")
                ?? defaults.string(forKey: "relay_token") ?? "",
            // the relay's key and other addresses (RelayRoute)
            "relay_pin": defaults.string(forKey: "relay_pin") ?? "",
            "relay_endpoints": defaults.array(forKey: "relay_endpoints") ?? [],
            // lets the watch say how old its copy is when it can't connect
            "sent_at": Date().timeIntervalSince1970,
        ]

        for alert in GameAlert.allCases {
            context[alert.rawValue] = alert.isOn(in: defaults)
        }

        for name in Self.syncedFiles {
            guard var data = try? Data(contentsOf: configDirectory.appendingPathComponent(name))
            else { continue }

            // the watch logs in with the accounts it's given instead
            if name == "options.ini", let options = String(data: data, encoding: .utf8) {
                data = Data(AccountStore.removingPassword(from: options).utf8)
            }

            context[name] = data
        }

        // left out while the keychain can't be read, so the watch doesn't
        // drop its accounts
        if let ids = AccountStore.shared.idsForWatch() {
            context[CompanionMessage.accountIDs] = ids
        }

        try? session.updateApplicationContext(context)
    }

    /// Sends the accounts the watch may have, after they change.
    func sendAccounts() {
        push()

        guard let session = reachableSession,
              let accounts = AccountStore.shared.encodedForWatch()
        else { return }

        session.sendMessage(
            [CompanionMessage.kind: CompanionMessage.accounts, CompanionMessage.accounts: accounts],
            replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Watching the iPhone game

    /// Sends the iPhone game's stats while the watch app is running.
    func send(status: GameStatus) {
        let dictionary = status.dictionary
        guard !(sentStatus.map { NSDictionary(dictionary: $0).isEqual(to: dictionary) } ?? false)
        else { return }

        guard let session = reachableSession else { return }
        sentStatus = dictionary

        session.sendMessage(
            [CompanionMessage.kind: CompanionMessage.status, CompanionMessage.status: dictionary],
            replyHandler: nil, errorHandler: { [weak self] _ in
                // try again with the next change
                DispatchQueue.main.async { self?.sentStatus = nil }
            })
    }

    /// Has the watch app tap for an alert, as iOS only shows the iPhone's
    /// notifications on the watch while the iPhone is locked.
    ///
    /// The iPhone can only message the watch app while it's on screen. With
    /// the wrist down it keeps running but isn't reachable, so the alert
    /// waits until the watch next asks for the status (every few seconds).
    func send(alert: GameAlert, title: String, body: String, isUrgent: Bool) {
        let message: [String: Any] = [
            CompanionMessage.kind: CompanionMessage.alert, CompanionMessage.alert: alert.rawValue,
            "title": title, "body": body, "urgent": isUrgent,
        ]

        guard let session = reachableSession else {
            keep(message)
            return
        }

        session.sendMessage(message, replyHandler: nil, errorHandler: { [weak self] _ in
            DispatchQueue.main.async { self?.keep(message) }
        })
    }

    private func keep(_ alert: [String: Any]) {
        // old alerts are no use by the time the watch asks
        pendingAlerts.removeAll { Date().timeIntervalSince($0.sent) > 60 }
        pendingAlerts.append((Date(), alert))
        if pendingAlerts.count > 10 {
            pendingAlerts.removeFirst()
        }
    }

    private var reachableSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        return session.activationState == .activated && session.isReachable ? session : nil
    }

    // MARK: - The watch's relay requests

    /// The route for the watch's requests: the iPhone's own relay settings,
    /// so the tailnet addresses (which the watch can't use) are tried too.
    private var watchRoute: (key: String, route: RelayRoute)?
    private let watchRouteLock = NSLock()

    private static let forwardedHeaders = ["Authorization", "X-RSC-Client", "Content-Type"]
    /// what one reply to the watch carries of a recv; the relay keeps the
    /// rest for the next one
    private static let maxForwardedBytes = 32 << 10

    private func routeForWatch() -> RelayRoute? {
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "relay_url")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: address), url.scheme == "https"
        else { return nil }

        let stored = RelayRoute.stored(in: defaults)
        let key = ([address, stored.pin ?? ""] + stored.endpoints.map { $0.url.absoluteString })
            .joined(separator: " ")

        watchRouteLock.lock()
        defer { watchRouteLock.unlock() }

        if let current = watchRoute, current.key == key {
            return current.route
        }
        let route = RelayRoute(primary: url, pin: stored.pin, endpoints: stored.endpoints, isWatch: false)
        watchRoute = (key, route)
        return route
    }

    /// Sends a request from the watch on to the relay, and replies with the
    /// relay's answer. Only to the paired relay's API, with the watch's own
    /// token, so the watch can't have the iPhone fetch anything else.
    private func forwardToRelay(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let method = message["method"] as? String, ["GET", "POST", "DELETE"].contains(method),
              let path = message["path"] as? String, path.hasPrefix("v1/"), !path.contains(".."),
              let route = routeForWatch()
        else {
            reply(["error": "the iPhone has no relay to send this to"])
            return
        }

        let headers = message["headers"] as? [String: String] ?? [:]

        DispatchQueue.main.async {
            // iOS may have started or woken this app just for the message
            var task = UIBackgroundTaskIdentifier.invalid
            let endTask = {
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
            task = UIApplication.shared.beginBackgroundTask(withName: "Relay for the watch", expirationHandler: endTask)

            let finish = { (answer: [String: Any]) in
                reply(answer)
                DispatchQueue.main.async(execute: endTask)
            }

            route.choose { base in
                var url = base.appendingPathComponent(path)
                if let query = message["query"] as? String,
                   var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.percentEncodedQuery = query
                    url = components.url ?? url
                }

                var request = URLRequest(url: url, timeoutInterval: 25)
                request.httpMethod = method
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.httpBody = message["body"] as? Data
                for name in Self.forwardedHeaders {
                    request.setValue(headers[name], forHTTPHeaderField: name)
                }
                // so the relay's log shows the watch came through the iPhone
                if let client = headers["X-RSC-Client"] {
                    request.setValue(client + " via iPhone", forHTTPHeaderField: "X-RSC-Client")
                }

                route.perform(request) { data, response, error in
                    guard let http = response as? HTTPURLResponse else {
                        route.forget()
                        finish(["error": error?.localizedDescription ?? "no answer from the relay"])
                        return
                    }

                    var body = data ?? Data()
                    if path.hasSuffix("/recv"), body.count > Self.maxForwardedBytes {
                        body = body.prefix(Self.maxForwardedBytes)
                    }

                    var replyHeaders: [String: String] = [:]
                    for case let (name as String, value as String) in http.allHeaderFields {
                        replyHeaders[name] = value
                    }

                    finish(["status": http.statusCode, "headers": replyHeaders, "body": body])
                }
            }
        }
    }

    // MARK: - WCSessionDelegate

    /// The watch app asks on launch whether the iPhone is playing.
    func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message[CompanionMessage.kind] as? String == CompanionMessage.relay {
            forwardToRelay(message, reply: replyHandler)
            return
        }

        if message[CompanionMessage.kind] as? String == CompanionMessage.accountsQuery {
            DispatchQueue.main.async {
                guard let accounts = AccountStore.shared.encodedForWatch() else {
                    replyHandler([:])
                    return
                }
                replyHandler([CompanionMessage.accounts: accounts])
            }
            return
        }

        guard message[CompanionMessage.kind] as? String == CompanionMessage.query else {
            replyHandler([:])
            return
        }

        DispatchQueue.main.async {
            let status = GameStatus.current()
            self.sentStatus = status.dictionary

            self.pendingAlerts.removeAll { Date().timeIntervalSince($0.sent) > 60 }
            let alerts = self.pendingAlerts.map { $0.message }
            self.pendingAlerts = []

            replyHandler([
                CompanionMessage.status: status.dictionary, CompanionMessage.alerts: alerts,
            ])
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        // the watch app opened or closed; send it everything again,
        // including the settings in case it was reinstalled
        DispatchQueue.main.async {
            self.sentStatus = nil
            if session.isReachable {
                self.push()
            }
        }
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async { self.push() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // switching to another paired watch
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.push() }
    }
}
