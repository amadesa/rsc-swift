import Foundation
import UIKit

/// Owns the rsc-c game thread and routes its callbacks back onto the main
/// thread.
final class GameClient {
    static let shared = GameClient()

    /// Called when the game focuses a text field: (current text, is password).
    var onKeyboardRequest: ((String, Bool) -> Void)?

    /// Called when the game's focused text field goes away.
    var onHideKeyboard: (() -> Void)?

    /// Called when "Add world" is tapped on the world list.
    var onWorldRequest: (() -> Void)?

    /// Called when "Remove" is tapped: (world index, world name).
    var onRemoveWorldRequest: ((Int, String) -> Void)?

    /// Called when "Register" is tapped: (world name, registration page or
    /// nil if the world has none).
    var onRegister: ((String, URL?) -> Void)?

    /// Called when "Accounts" is tapped on the welcome screen.
    var onAccountsRequest: (() -> Void)?

    /// Called when the game couldn't connect through the relay, with a check
    /// of each link from this device to the game server.
    var onRelayProblem: (([RelayCheck.Step]) -> Void)?

    private let audio = GameAudio()
    private var relay: RelayTransport?
    private(set) var isStarted = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// reads the player's state for GameAlerts
    private var statusTimer: Timer?
    private var status = GameStatus()
    /// playing silence so iOS doesn't suspend the game in the background
    private var isKeepingAlive = false

    var isLoggedIn: Bool { rsc_is_logged_in() != 0 }

    private init() {}

    func start(width: Int, height: Int) {
        guard !isStarted else { return }
        isStarted = true

        installRelayIfEnabled()

        guard let cacheDirectory = Bundle.main
            .url(forResource: "config85", withExtension: "jag")?
            .deletingLastPathComponent()
        else {
            fatalError("game cache files are missing from the app bundle")
        }

        let configDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        excludeFromBackup(configDirectory)
        PhoneWatchSync.shared.start(configDirectory: configDirectory)
        let optionsURL = configDirectory.appendingPathComponent("options.ini")
        removeStoredPassword(optionsURL)

        var config = RscConfig()
        config.width = Int32(width)
        config.height = Int32(height)
        config.members = 1
        config.context = Unmanaged.passUnretained(self).toOpaque()

        config.on_keyboard = { context, text, isPassword in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let current = text.map { String(cString: $0) } ?? ""

            DispatchQueue.main.async {
                client.onKeyboardRequest?(current, isPassword != 0)
            }
        }

        config.on_hide_keyboard = { context in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()

            DispatchQueue.main.async {
                client.onHideKeyboard?()
            }
        }

        config.on_sound = { context, pcm, samples, sampleRate in
            guard let pcm = pcm, samples > 0 else { return }

            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let buffer = Array(UnsafeBufferPointer(start: pcm, count: Int(samples)))

            client.audio.play(buffer, sampleRate: Double(sampleRate))
        }

        config.on_message = { _, message, type in
            guard let message = message else { return }
            let text = String(cString: message)

            DispatchQueue.main.async {
                GameAlerts.shared.check(message: text, type: Int(type))
            }
        }

        config.on_open_url = { _, url in
            guard let url = url, let link = URL(string: String(cString: url)) else { return }

            DispatchQueue.main.async {
                UIApplication.shared.open(link)
            }
        }

        config.on_request_world = { context in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()

            DispatchQueue.main.async {
                client.onWorldRequest?()
            }
        }

        config.on_request_remove_world = { context, index, name in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let worldName = name.map { String(cString: $0) } ?? ""

            DispatchQueue.main.async {
                client.onRemoveWorldRequest?(Int(index), worldName)
            }
        }

        config.on_register = { context, name, url in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let worldName = name.map { String(cString: $0) } ?? ""
            let link = url.flatMap { URL(string: String(cString: $0)) }

            DispatchQueue.main.async {
                client.onRegister?(worldName, link)
            }
        }

        config.on_request_accounts = { context in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()

            DispatchQueue.main.async {
                client.onAccountsRequest?()
            }
        }

        config.on_login = { _, username, password, worldName, host, port in
            guard let username = username, let password = password, let host = host
            else { return }

            let account = (
                username: String(cString: username), password: String(cString: password),
                worldName: worldName.map { String(cString: $0) } ?? "",
                host: String(cString: host), port: Int(port))

            DispatchQueue.main.async {
                AccountStore.shared.remember(
                    username: account.username, password: account.password,
                    worldName: account.worldName, host: account.host, port: account.port)
                PhoneWatchSync.shared.sendAccounts()
            }
        }

        GameAlerts.shared.start()
        GameAlerts.shared.forward = { alert, title, body, isUrgent in
            PhoneWatchSync.shared.send(alert: alert, title: title, body: body, isUrgent: isUrgent)
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        // the game shows it as a checkbox in Additional options
        rsc_set_stay_connected(Self.isStayingConnected ? 1 : 0)

        // rsc_start copies the path strings before returning
        cacheDirectory.path.withCString { cachePath in
            configDirectory.path.withCString { configPath in
                config.cache_dir = cachePath
                config.config_dir = configPath
                rsc_start(&config)
            }
        }

        fillInRememberedLogin(optionsURL)
    }

    /// Older versions saved the remembered password in options.ini in
    /// plain text. Clears it once the keychain has that login, so nothing
    /// is lost; until then the next login moves it there.
    private func removeStoredPassword(_ optionsURL: URL) {
        guard let options = try? String(contentsOf: optionsURL, encoding: .utf8),
              let username = AccountStore.value(of: "username", in: options),
              let password = AccountStore.value(of: "password", in: options),
              !password.isEmpty,
              let accounts = AccountStore.shared.all(), // nil while locked
              accounts.contains(where: {
                  $0.username.caseInsensitiveCompare(username) == .orderedSame
                      && $0.password == password
              })
        else { return }

        try? AccountStore.removingPassword(from: options)
            .write(to: optionsURL, atomically: true, encoding: .utf8)
    }

    /// The game remembers the username in options.ini; the password comes
    /// from the keychain, for the login screen to show as before.
    private func fillInRememberedLogin(_ optionsURL: URL) {
        guard let options = try? String(contentsOf: optionsURL, encoding: .utf8),
              AccountStore.value(of: "remember_password", in: options) != "0",
              let username = AccountStore.value(of: "username", in: options),
              !username.isEmpty,
              let account = AccountStore.shared.all()?.first(where: { // most recent first
                  $0.username.caseInsensitiveCompare(username) == .orderedSame
              })
        else { return }

        rsc_set_login(account.username, account.password)
    }

    private func updateStatus() {
        let current = GameStatus.current()

        if current != status {
            // nothing left to stay connected for, so let iOS suspend the app
            if isKeepingAlive && status.isLoggedIn && !current.isLoggedIn {
                isKeepingAlive = false
                audio.stopKeepingAlive()
            }

            // the login's username was just saved to options.ini; the
            // watch uses it too unless it's playing with its own account
            if current.isLoggedIn && !status.isLoggedIn {
                PhoneWatchSync.shared.push()
            }

            status = current
            GameAlerts.shared.check(current)
        }

        // every time, as it only sends changes, and resends everything once
        // the watch app opens
        PhoneWatchSync.shared.send(status: status)
    }

    func add(_ world: WorldConfig) {
        world.name.withCString { name in
            world.host.withCString { host in
                world.rsaExponent.withCString { exponent in
                    world.rsaModulus.withCString { modulus in
                        (world.registerURL ?? "").withCString { registerURL in
                            rsc_add_world(
                                name, host, Int32(world.port), exponent, modulus,
                                registerURL)
                        }
                    }
                }
            }
        }
    }

    func removeWorld(at index: Int) {
        rsc_remove_world(Int32(index))
    }

    /// Logs in with a saved account, on its world.
    func logIn(_ account: SavedAccount) {
        rsc_login(account.username, account.password, account.host, Int32(account.port))
    }

    private static let stayConnectedKey = "stay_connected_in_background"

    /// Settings > RSC > Stay connected in the background, also a checkbox in
    /// the game's Additional options > Game. On until turned off.
    static var isStayingConnected: Bool {
        get { UserDefaults.standard.bool(forKey: stayConnectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: stayConnectedKey) }
    }

    /// Defaults for the Settings app page, which iOS doesn't apply itself.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [stayConnectedKey: true])
    }

    /// iOS gives an app about 30 seconds of running time after it's left
    /// before suspending it. Using that keeps the connection alive for quick
    /// app switches; the server allows another 30 seconds of silence before
    /// logging the player out. After longer absences the client's automatic
    /// reconnect logs back in with the stored credentials on return.
    ///
    /// With Settings > RSC > Stay connected in the background, the game
    /// keeps running instead, playing silence (see GameAudio).
    func enterBackground() {
        rsc_set_background(1)
        GameAlerts.shared.isActive = false

        // options and worlds may have changed while playing
        PhoneWatchSync.shared.push()

        // the checkbox in Additional options may have changed it
        Self.isStayingConnected = rsc_get_stay_connected() != 0

        isKeepingAlive = isLoggedIn && Self.isStayingConnected
        audio.setBackground(true, keepAlive: isKeepingAlive)

        guard isLoggedIn, !isKeepingAlive, backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Stay connected") { [weak self] in
            GameAlerts.shared.appWillSuspend()
            self?.endBackgroundTask()
        }
    }

    func enterForeground() {
        // or the switch in Settings > RSC
        rsc_set_stay_connected(Self.isStayingConnected ? 1 : 0)
        rsc_set_background(0)
        GameAlerts.shared.isActive = true
        endBackgroundTask()

        isKeepingAlive = false
        audio.setBackground(false, keepAlive: false)

        // alerts may have been changed in Settings
        PhoneWatchSync.shared.push()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Uses the relay settings as they are now, e.g. after pairing. New
    /// connections go through it; one already open carries on as it was.
    func reloadRelay() {
        installRelayIfEnabled()
    }

    /// Settings > RSC > Relay: connect through rsc-relay over HTTPS instead
    /// of directly, as the Apple Watch app must (see RelayTransport).
    private func installRelayIfEnabled() {
        let defaults = UserDefaults.standard

        guard defaults.bool(forKey: "relay_enabled"),
              let address = defaults.string(forKey: "relay_url")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: address), url.scheme == "https",
              let token = defaults.string(forKey: "relay_token")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return }

        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let stored = RelayRoute.stored(in: defaults)
        let relay = RelayTransport(settings: .init(
            baseURL: url, token: token, device: device,
            pin: stored.pin, endpoints: stored.endpoints))

        relay.onOpenFailed = { [weak self, weak relay] host, port, _ in
            guard let route = relay?.route else { return }
            RelayCheck.run(
                baseURL: route.base, token: token, client: RelayCheck.clientName(device),
                host: host, port: port, isWatch: false, route: route
            ) { steps in
                self?.onRelayProblem?(steps)
            }
        }

        relay.install()
        self.relay = relay

        updateRelayInfo(route: relay.route, token: token, device: device)
    }

    /// Asks the relay for its key and the addresses it's reachable at, and
    /// passes them to the watch, which needs them when the relay URL doesn't
    /// work for it. Used from the next launch on here.
    private func updateRelayInfo(route: RelayRoute, token: String, device: String) {
        route.fetchInfo(token: token, client: RelayCheck.clientName(device)) { info in
            guard let info = info else { return }

            let defaults = UserDefaults.standard
            let old = RelayRoute.stored(in: defaults)
            guard old.pin != info.pin || old.endpoints != info.endpoints else { return }

            if let pin = old.pin, pin != info.pin {
                // only reachable through the relay URL, which is checked
                // like any website, so the relay's new key is trusted
                print("relay: its key changed from \(pin) to \(info.pin)")
            }

            RelayRoute.store(info, in: defaults)
            PhoneWatchSync.shared.push()
        }
    }

    /// Keep the settings folder (options.ini and worlds.cfg) out of iCloud
    /// and computer backups: they're this phone's, and options.ini from an
    /// older version can still hold a password until it's cleared.
    /// Excluding the folder covers files created later.
    private func excludeFromBackup(_ directory: URL) {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    func resize(width: Int, height: Int) {
        rsc_resize(Int32(width), Int32(height))
    }
}
