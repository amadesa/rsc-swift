import Foundation
import WatchConnectivity

/// Receives what the iPhone app sends (PhoneWatchSync): the relay settings,
/// copies of options.ini, worlds.cfg and combat-styles.cfg, and the accounts
/// it shares, so the watch plays with the same accounts, worlds and options
/// without typing anything.
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    static let syncedFiles = ["options.ini", "worlds.cfg", "combat-styles.cfg"]

    let configDirectory: URL = {
        let directory = AppDirectories.applicationSupport
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // nothing here is worth restoring from a backup
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        return directory
    }()

    /// The iPhone's game stats, which it sends while this app is running.
    var onPhoneStatus: ((GameStatus) -> Void)?

    /// New settings from the iPhone have been saved.
    var onSettings: (() -> Void)?

    private var onReady: (() -> Void)?
    private var isReady = false

    var relaySettings: RelayTransport.Settings? {
        let defaults = UserDefaults.standard

        guard let address = defaults.string(forKey: "relay_url"),
              let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let token = defaults.string(forKey: "relay_token")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }

        let stored = RelayRoute.stored(in: defaults)
        return RelayTransport.Settings(
            baseURL: url, token: token, device: "watch", isWatch: true,
            pin: stored.pin, endpoints: stored.endpoints, forwarder: forward)
    }

    /// When the iPhone sent the settings the watch has, if it ever did.
    var lastSynced: Date? {
        let sentAt = UserDefaults.standard.double(forKey: "sent_at")
        return sentAt > 0 ? Date(timeIntervalSince1970: sentAt) : nil
    }

    /// The relay address the watch has, for showing which machine it tries.
    var relayHost: String? {
        UserDefaults.standard.string(forKey: "relay_url").flatMap { URL(string: $0)?.host }
    }

    /// Calls `ready` on the main thread once the latest settings from the
    /// iPhone are in place (or straight away if the link isn't available).
    func activate(ready: @escaping () -> Void) {
        guard WCSession.isSupported() else {
            ready()
            return
        }

        onReady = ready

        let session = WCSession.default
        session.delegate = self
        session.activate()

        // don't wait forever if the phone link is slow to come up
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.markReady() }
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        onReady?()
        onReady = nil
    }

    private func save(_ context: [String: Any]) {
        let defaults = UserDefaults.standard

        if let url = context["relay_url"] as? String {
            defaults.set(url, forKey: "relay_url")
        }
        if let token = context["relay_token"] as? String {
            defaults.set(token, forKey: "relay_token")
        }
        if let pin = context["relay_pin"] as? String {
            defaults.set(pin.isEmpty ? nil : pin, forKey: "relay_pin")
        }
        if let endpoints = context["relay_endpoints"] as? [[String: String]] {
            defaults.set(endpoints, forKey: "relay_endpoints")
        }
        if let sentAt = context["sent_at"] as? Double {
            defaults.set(sentAt, forKey: "sent_at")
        }

        for alert in GameAlert.allCases {
            if let isOn = context[alert.rawValue] as? Bool {
                defaults.set(isOn, forKey: alert.rawValue)
            }
        }

        // the game reads these when it starts, so a later update takes effect
        // on the next launch (except the login, see below)
        for name in Self.syncedFiles where name != "options.ini" {
            if let data = context[name] as? Data {
                try? data.write(to: configDirectory.appendingPathComponent(name), options: .atomic)
            }
        }

        if let data = context["options.ini"] as? Data, let options = String(data: data, encoding: .utf8) {
            saveOptions(options, isFromPhone: true)
        }

        // accounts the iPhone stopped sharing or removed
        if let ids = context[CompanionMessage.accountIDs] as? [String] {
            AccountStore.shared.keepPhoneAccounts(ids: ids)
        }
    }

    // MARK: - Accounts

    /// options.ini without a password, and no copy of the iPhone's, which
    /// older versions kept: the watch's accounts are in the keychain.
    private func saveOptions(_ options: String, isFromPhone: Bool = false) {
        var options = AccountStore.removingPassword(from: options)

        if isFromPhone {
            options = keepingWatchSettings(in: options)
        }

        try? options.write(to: optionsURL, atomically: true, encoding: .utf8)
    }

    /// The watch's display settings, which both the iPhone's Additional
    /// options and the watch's own Options tab change.
    static let watchSettings = ["watch_tab_panels", "watch_tab_full_screen",
                                "watch_keyboard_button"]

    /// The iPhone's options.ini, with the watch's own value for each of its
    /// settings, unless the iPhone has changed that setting since it last
    /// sent it: the latest change wins.
    private func keepingWatchSettings(in phoneOptions: String) -> String {
        let defaults = UserDefaults.standard
        let key = "phone_watch_settings"
        let lastFromPhone = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let watchOptions = (try? String(contentsOf: optionsURL, encoding: .utf8)) ?? ""

        var options = phoneOptions
        var fromPhone: [String: String] = [:]

        for name in Self.watchSettings {
            guard let phoneValue = Self.value(of: name, in: phoneOptions) else { continue }
            fromPhone[name] = phoneValue

            if phoneValue == lastFromPhone[name],
               let watchValue = Self.value(of: name, in: watchOptions),
               watchValue != phoneValue {
                options = Self.setting(name, to: watchValue, in: options)
            }
        }

        defaults.set(fromPhone, forKey: key)
        return options
    }

    /// A setting's value in options.ini, e.g. "1" for "watch_tab_panels".
    private static func value(of name: String, in options: String) -> String? {
        for line in options.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1)

            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    private static func setting(_ name: String, to value: String, in options: String) -> String {
        options.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let parts = line.split(separator: "=", maxSplits: 1)

            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == name {
                return "\(name) = \(value)"
            }

            return String(line)
        }
        .joined(separator: "\n")
    }

    private var optionsURL: URL {
        configDirectory.appendingPathComponent("options.ini")
    }

    /// Clears passwords older versions saved in plain text. Called before
    /// the game reads options.ini.
    func removeStoredPasswords() {
        try? FileManager.default.removeItem(
            at: configDirectory.appendingPathComponent("iphone-options.ini"))

        if let options = try? String(contentsOf: optionsURL, encoding: .utf8) {
            saveOptions(options)
        }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "uses_own_account")
    }

    /// Asks the iPhone for the accounts it shares with the watch, and keeps
    /// them. `done` is called on the main thread, whether or not it answered.
    func fetchAccounts(_ done: @escaping () -> Void = {}) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            done()
            return
        }

        WCSession.default.sendMessage(
            [CompanionMessage.kind: CompanionMessage.accountsQuery],
            replyHandler: { response in
                DispatchQueue.main.async {
                    if let accounts = response[CompanionMessage.accounts] as? Data {
                        AccountStore.shared.replacePhoneAccounts(with: accounts)
                    }
                    done()
                }
            },
            errorHandler: { _ in DispatchQueue.main.async { done() } })
    }

    // MARK: - Watching the iPhone game

    /// Asks whether the iPhone is playing right now; `answer` gets its
    /// status on the main thread, or nil if the iPhone didn't answer. Alerts
    /// the iPhone kept for the watch are fired (see PhoneWatchSync.send).
    func askPhoneStatus(_ answer: @escaping (GameStatus?) -> Void) {
        // isReachable is often false while this app is in the background,
        // yet a message still gets through, so it's only a hint
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            answer(nil)
            return
        }

        var isAnswered = false
        func reply(_ status: GameStatus?) {
            DispatchQueue.main.async {
                guard !isAnswered else { return }
                isAnswered = true
                answer(status)
            }
        }

        WCSession.default.sendMessage(
            [CompanionMessage.kind: CompanionMessage.query],
            replyHandler: { response in
                let alerts = response[CompanionMessage.alerts] as? [[String: Any]] ?? []
                DispatchQueue.main.async { alerts.forEach(self.fire) }

                let dictionary = response[CompanionMessage.status] as? [String: Any]
                reply(dictionary.map { GameStatus(dictionary: $0) })
            },
            errorHandler: { _ in reply(nil) })

        // don't hold up playing if the iPhone is slow to answer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply(nil) }
    }

    // MARK: - The relay through the iPhone

    /// Has the iPhone send a request to the relay (PhoneWatchSync), for
    /// when the watch can't reach it: away from home with the iPhone's
    /// Tailscale DNS on. Calls back like a data task, on a background queue.
    func forward(_ request: URLRequest, _ done: @escaping (Data?, URLResponse?, Error?) -> Void) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let url = request.url
        else {
            done(nil, nil, URLError(.notConnectedToInternet))
            return
        }

        var message: [String: Any] = [
            CompanionMessage.kind: CompanionMessage.relay,
            "method": request.httpMethod ?? "GET",
            "path": String(url.path.drop { $0 == "/" }),
            "headers": request.allHTTPHeaderFields ?? [:],
        ]
        if let query = url.query {
            message["query"] = query
        }
        if let body = request.httpBody {
            message["body"] = body
        }

        // answered once: by the iPhone, its error, or the timeout
        let lock = NSLock()
        var isAnswered = false
        let answer = { (data: Data?, response: URLResponse?, error: Error?) in
            lock.lock()
            let isFirst = !isAnswered
            isAnswered = true
            lock.unlock()
            if isFirst { done(data, response, error) }
        }

        // isReachable is only a hint (see askPhoneStatus), so just try
        WCSession.default.sendMessage(message, replyHandler: { reply in
            guard let status = reply["status"] as? Int,
                  let response = HTTPURLResponse(
                      url: url, statusCode: status, httpVersion: "HTTP/1.1",
                      headerFields: reply["headers"] as? [String: String])
            else {
                answer(nil, nil, URLError(.cannotConnectToHost))
                return
            }
            answer(reply["body"] as? Data ?? Data(), response, nil)
        }, errorHandler: { error in
            answer(nil, nil, error)
        })

        // like the relay session's own limit (RelayRoute)
        DispatchQueue.global().asyncAfter(deadline: .now() + min(request.timeoutInterval, 30)) {
            answer(nil, nil, URLError(.timedOut))
        }
    }

    private func fire(_ message: [String: Any]) {
        guard let key = message[CompanionMessage.alert] as? String,
              let alert = GameAlert(rawValue: key)
        else { return }

        GameAlerts.shared.fire(
            alert, message["title"] as? String ?? "RSC", message["body"] as? String ?? "",
            isUrgent: message["urgent"] as? Bool ?? false)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            switch message[CompanionMessage.kind] as? String {
            case CompanionMessage.status:
                if let dictionary = message[CompanionMessage.status] as? [String: Any] {
                    self.onPhoneStatus?(GameStatus(dictionary: dictionary))
                }

            case CompanionMessage.alert:
                self.fire(message)

            case CompanionMessage.accounts:
                if let accounts = message[CompanionMessage.accounts] as? Data {
                    AccountStore.shared.replacePhoneAccounts(with: accounts)
                }

            default:
                break
            }
        }
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext

        DispatchQueue.main.async {
            self.save(context)
            self.markReady()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.save(applicationContext)
            self.onSettings?()
        }
    }
}
