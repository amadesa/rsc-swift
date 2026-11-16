import CoreGraphics
import Foundation

/// Runs the rsc-c client on the watch. watchOS only allows HTTPS, so the
/// game always connects through rsc-relay (RelayTransport), using the relay
/// settings synced from the iPhone.
final class WatchGame: ObservableObject {
    static let shared = WatchGame()

    @Published private(set) var frame: CGImage?
    /// shown instead of the game when it can't start
    @Published private(set) var message: String? = "Loading…"
    /// non-nil while the game wants text typed (e.g. chat or the sleep word)
    @Published var textRequest: TextRequest?
    /// hits, prayer, fatigue and combat style, shown over the game
    @Published private(set) var status = Status()
    /// whether the ui tab icons (inventory, map...) are showing
    @Published private(set) var areTabsRevealed = false
    /// the right click ("Choose option") menu, shown as a watch list
    @Published var menu: Menu?
    /// why the last login couldn't get through the relay, link by link
    @Published var relayProblem: RelayProblem?
    /// the iPhone's game, while the watch is just watching it rather than
    /// playing (see watchPhone)
    @Published private(set) var phoneStatus: GameStatus?

    /// the RuneScape logo from the game's login screen, for the watch's
    @Published private(set) var logo: CGImage?
    /// the game's login screen, which the watch shows its own way
    @Published private(set) var login = LoginState()
    /// the saved accounts, most recently used first
    @Published private(set) var accounts: [SavedAccount] = []
    /// the account being logged in to
    @Published private(set) var loggingInAs: String?
    /// why the last login didn't work
    @Published var loginError: String?
    /// the iPhone hasn't answered whether it has accounts for the watch
    @Published private(set) var isFetchingAccounts = false

    /// the last alert, shown on top for a few seconds
    @Published var alertBanner: AlertBanner?

    struct AlertBanner: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    private var hideBannerWork: DispatchWorkItem?

    struct Menu: Identifiable {
        let id = UUID()
        /// may contain @col@ colour codes
        let items: [String]
    }

    typealias Status = GameStatus

    struct RelayProblem: Identifiable {
        let id = UUID()
        let steps: [RelayCheck.Step]
        /// what to retry with
        let host: String
        let port: Int
    }

    struct LoginState: Equatable {
        var isReady = false
        /// LOGIN_STAGE: 0 welcome, 2 existing user, 4 world list
        var screen = 0
        var isOptionsOpen = false
        var loginsFinished = 0
        var status = ""
        var worldName = ""
        var worldHost = ""
        var worldPort = 0
        /// where the RuneScape logo is in the frame
        var logoY = 0
        var logoHeight = 0
        /// the 2001 game's data, for a 2001Scape world: 0 here or not
        /// needed, 1 downloading, 2 the download failed
        var retroData = 0

        var isDownloadingRetroData: Bool { retroData == 1 }
        /// until another world is chosen (which clears the status)
        var didRetroDownloadFail: Bool { retroData == 2 && !status.isEmpty }

        /// on the welcome or login screen, which the watch shows itself
        var isAccountScreen: Bool { isReady && !isOptionsOpen && (screen == 0 || screen == 2) }

        static func current() -> LoginState {
            var state = RscLoginState()
            rsc_get_login_state(&state)

            func text<T>(_ tuple: T) -> String {
                withUnsafeBytes(of: tuple) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
            }

            let status = [text(state.status), text(state.status_bottom)]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            return LoginState(
                isReady: state.ready != 0, screen: Int(state.screen),
                isOptionsOpen: state.options_open != 0,
                loginsFinished: Int(state.logins_finished), status: status,
                worldName: text(state.world_name), worldHost: text(state.world_host),
                worldPort: Int(state.world_port), logoY: Int(state.logo_y),
                logoHeight: Int(state.logo_height), retroData: Int(state.retro_data))
        }
    }

    struct TextRequest: Identifiable {
        let id = UUID()
        let text: String
        let isPassword: Bool
    }

    private var relay: RelayTransport?
    private var timer: Timer?
    private var lastSerial: UInt64 = 0
    /// where the finger last was, normalized. not published, so touches
    /// don't redraw the view
    var lastTouch = CGPoint.zero

    /// the game's menu is open, waiting for chooseMenuItem
    private var isMenuOpen = false
    private var hideTabsWork: DispatchWorkItem?
    private var isStarted = false
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// The client's minimum width; the height follows the screen's shape.
    static let gameWidth = 320

    func start(screenSize: CGSize) {
        guard !isStarted, screenSize.width > 0 else { return }
        isStarted = true
        self.screenSize = screenSize

        GameAlerts.shared.show = { [weak self] title, body in
            self?.showBanner(title, body)
        }

        KeepAlive.shared.isNeeded = { [weak self] in
            self?.phoneStatus != nil || self?.status.isLoggedIn == true
        }

        // the iPhone sends its status as soon as it sees this app open
        // (which can be after the question below goes unanswered) and
        // whenever it changes
        WatchSync.shared.onPhoneStatus = { [weak self] status in
            self?.phoneStatusChanged(status)
        }

        // the settings can arrive after this app opens, e.g. after a reinstall
        WatchSync.shared.onSettings = { [weak self] in
            guard let self = self, self.isWaitingForSettings else { return }
            self.startGame(screenSize: self.screenSize)
        }

        reloadAccounts()
        NotificationCenter.default.addObserver(
            forName: AccountStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadAccounts()
        }

        WatchSync.shared.activate { [weak self] in
            self?.startPolling()
            self?.fetchAccounts()

            // logging in here too would log the iPhone out
            WatchSync.shared.askPhoneStatus { status in
                guard let self = self, self.phoneStatus == nil, !self.isGameStarted else { return }

                if let status = status, status.isLoggedIn {
                    self.watchPhone(status)
                } else {
                    self.startGame(screenSize: screenSize)
                }
            }
        }
    }

    private var screenSize = CGSize.zero
    private var isWaitingForSettings = false
    private var isGameStarted: Bool { timer != nil }

    /// Whether the iPhone logging in switches to watching it. Off after
    /// choosing Play on watch while it's logged in, until it logs out.
    private var followsPhoneLogin = true

    /// Switches to watching the iPhone when it logs in, unless the watch is
    /// playing: logging in on one would log the other out, and it's for the
    /// player to say which.
    private func phoneStatusChanged(_ status: GameStatus) {
        if !status.isLoggedIn {
            followsPhoneLogin = true
        }

        if phoneStatus != nil {
            phoneStatus = status
        } else if status.isLoggedIn && followsPhoneLogin && !self.status.isLoggedIn {
            watchPhone(status)
        }
    }

    /// Shows the iPhone game's stats and taps for its alerts, which the
    /// iPhone sends while this app is running. A watch game that's already
    /// started stays at its login screen underneath.
    private func watchPhone(_ status: GameStatus) {
        isWaitingForSettings = false
        message = nil
        textRequest = nil
        phoneStatus = status
        GameAlerts.shared.start()
    }

    private var pollTimer: Timer?
    private var isPolling = false

    /// Asks the iPhone for its status and alerts every 2 seconds, as it
    /// can't message this app while the wrist is down: while watching it, and
    /// while the watch isn't logged in itself, to notice the iPhone logging
    /// in.
    private func startPolling() {
        guard pollTimer == nil else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPolling else { return }
            guard self.phoneStatus != nil || !self.status.isLoggedIn else { return }

            self.isPolling = true
            WatchSync.shared.askPhoneStatus { status in
                self.isPolling = false
                if let status = status {
                    self.phoneStatusChanged(status)
                }
            }
        }
    }

    // MARK: - Accounts

    /// the login being waited for finishes once loginsFinished passes this
    private var loginsFinishedBefore = 0

    private func reloadAccounts() {
        // nil while the watch is locked; keep what's showing
        if let accounts = AccountStore.shared.all() {
            self.accounts = accounts
        }
    }

    func fetchAccounts() {
        isFetchingAccounts = true
        WatchSync.shared.fetchAccounts { [weak self] in
            self?.isFetchingAccounts = false
            self?.reloadAccounts()
        }
    }

    /// Logs in with a saved account, on its world.
    func logIn(_ account: SavedAccount) {
        logIn(username: account.username, password: account.password,
              host: account.host, port: account.port)
    }

    /// Logs in with a new account on the selected world; it's saved on the
    /// watch if the server accepts it.
    func logIn(username: String, password: String) {
        logIn(username: username, password: password,
              host: login.worldHost, port: login.worldPort)
    }

    private func logIn(username: String, password: String, host: String, port: Int) {
        guard loggingInAs == nil, !status.isLoggedIn else { return }

        loginError = nil
        loggingInAs = username
        loginsFinishedBefore = login.loginsFinished
        rsc_login(username, password, host, Int32(port))
    }

    func removeAccount(_ account: SavedAccount) {
        AccountStore.shared.remove(id: account.id)
        reloadAccounts()
    }

    /// The game's world list, to pick the world for a new account.
    func showWorlds() {
        rsc_show_login_screen(RSC_LOGIN_SCREEN_WORLDS)
    }

    /// The game's options (Additional options).
    func showOptions() {
        rsc_show_login_screen(RSC_LOGIN_SCREEN_OPTIONS)
    }

    private func updateLogin() {
        let current = LoginState.current()
        guard current != login else { return }

        if loggingInAs != nil, current.loginsFinished > loginsFinishedBefore {
            loggingInAs = nil

            if !rscIsLoggedIn {
                loginError = current.status.isEmpty ? "Couldn't log in." : current.status
            }
        }

        login = current
    }

    private var rscIsLoggedIn: Bool { rsc_is_logged_in() != 0 }

    /// The Watch iPhone button on the watch's login screen.
    func watchPhoneNow() {
        WatchSync.shared.askPhoneStatus { [weak self] status in
            guard let self = self, self.phoneStatus == nil, !self.status.isLoggedIn else { return }

            guard let status = status else {
                self.showBanner("Can't reach the iPhone",
                                "Open RSC on the iPhone and keep it nearby, then try again.")
                return
            }

            self.followsPhoneLogin = true
            self.watchPhone(status)
        }
    }

    private func showBanner(_ title: String, _ body: String) {
        alertBanner = AlertBanner(title: title, body: body)

        hideBannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.alertBanner = nil }
        hideBannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    /// Stops watching the iPhone and starts the game on the watch.
    func playOnWatch() {
        guard let phone = phoneStatus else { return }

        // stay on the watch until the iPhone logs out and in again
        followsPhoneLogin = !phone.isLoggedIn
        phoneStatus = nil

        if !isGameStarted {
            message = "Loading…"
            startGame(screenSize: screenSize)
        }
    }

    #if targetEnvironment(simulator)
    /// For testing in the simulator: with RSC_TEST_USERNAME,
    /// RSC_TEST_PASSWORD, RSC_TEST_HOST and RSC_TEST_PORT in the environment
    /// (`SIMCTL_CHILD_` ones from `simctl launch`), logs in once the game has
    /// loaded, taps at RSC_TEST_TAPS, then opens the ui tab numbered
    /// RSC_TEST_TAB, if given. RSC_TEST_REVEAL_TABS=1 brings out the tab
    /// icons, as turning the crown does.
    private func startSimulatorTest() {
        let environment = ProcessInfo.processInfo.environment

        guard let username = environment["RSC_TEST_USERNAME"],
              let password = environment["RSC_TEST_PASSWORD"],
              let host = environment["RSC_TEST_HOST"],
              let port = Int32(environment["RSC_TEST_PORT"] ?? "")
        else { return }

        let tab = Int32(environment["RSC_TEST_TAB"] ?? "")
        var loginsFinished: Int32?

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            guard rsc_is_logged_in() == 0 else {
                timer.invalidate()
                self.runSimulatorTest(environment: environment, tab: tab)
                return
            }

            var state = RscLoginState()
            rsc_get_login_state(&state)
            guard state.ready != 0 else { return }

            // log in, and again whenever that fails (e.g. while the server
            // still has the account from the last run)
            if let started = loginsFinished {
                guard state.logins_finished > started else { return }

                let status = withUnsafeBytes(of: state.status) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let bottom = withUnsafeBytes(of: state.status_bottom) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                NSLog("RSC test: login failed: %@ %@", status, bottom)
            }

            loginsFinished = state.logins_finished
            NSLog("RSC test: logging in")
            rsc_login(username, password, host, port)
        }
    }

    private func runSimulatorTest(environment: [String: String], tab: Int32?) {
        NSLog("RSC test: logged in")

        // RSC_TEST_TAPS: taps a second apart once the world has loaded,
        // as "x,y;x,y" from 0 to 1 across the screen
        let taps = Self.testTaps(environment["RSC_TEST_TAPS"])

        // RSC_TEST_TAB_TAPS: the same, once the tab is open
        let tabTaps = Self.testTaps(environment["RSC_TEST_TAB_TAPS"])

        Self.tap(taps, after: 8)

        if environment["RSC_TEST_REVEAL_TABS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.setTabsRevealed(true)
            }
        }

        if let tab = tab {
            let tabTime = 9 + Double(taps.count)

            DispatchQueue.main.asyncAfter(deadline: .now() + tabTime) {
                rsc_show_ui_tab(tab)
            }

            Self.tap(tabTaps, after: tabTime + 2)
        }
    }

    private static func testTaps(_ list: String?) -> [(Float, Float)] {
        (list ?? "")
            .split(separator: ";")
            .compactMap { tap -> (Float, Float)? in
                let parts = tap.split(separator: ",").compactMap { Float($0) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
    }

    private static func tap(_ taps: [(Float, Float)], after delay: Double) {
        for (index, tap) in taps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(index)) {
                rsc_touch(RSC_TOUCH_DOWN, 1, tap.0, tap.1)

                // a frame or two apart, as a finger would
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    rsc_touch(RSC_TOUCH_UP, 1, tap.0, tap.1)
                }
            }
        }
    }
    #endif

    private func installRelay(_ settings: RelayTransport.Settings) {
        let relay = RelayTransport(settings: settings)

        relay.onOpenFailed = { [weak self] host, port, _ in
            self?.checkRelay(host: host, port: port)
        }

        relay.install()
        self.relay = relay

        // the relay's key and other addresses usually come from the iPhone;
        // when the relay URL works here too, ask it directly
        relay.route.fetchInfo(token: settings.token, client: RelayCheck.clientName(settings.device)) { info in
            guard let info = info else { return }
            let old = RelayRoute.stored(in: .standard)
            if old.pin != info.pin || old.endpoints != info.endpoints {
                RelayRoute.store(info, in: .standard)
            }
        }
    }

    private func startGame(screenSize: CGSize) {
        if let settings = WatchSync.shared.relaySettings {
            isWaitingForSettings = false
            installRelay(settings)
        } else {
            #if targetEnvironment(simulator)
            // the simulator has the Mac's network, so for testing it
            // connects straight to the game server, as the iPhone can
            isWaitingForSettings = false
            #else
            isWaitingForSettings = true
            message = "Log in to RSC on your iPhone to follow it here.\n\nTo play on the watch itself, set up rsc-relay in the iPhone's Settings > RSC, then open RSC on the iPhone."
            return
            #endif
        }

        guard let cacheDirectory = Bundle.main
            .url(forResource: "config85", withExtension: "jag")?
            .deletingLastPathComponent()
        else {
            message = "The game data is missing from the app."
            return
        }

        let height = Int((CGFloat(Self.gameWidth) * screenSize.height / screenSize.width).rounded())

        var config = RscConfig()
        config.width = Int32(Self.gameWidth)
        config.height = Int32(max(height, 240))
        config.members = 1
        config.context = Unmanaged.passUnretained(self).toOpaque()

        config.on_keyboard = { context, text, isPassword in
            let game = Unmanaged<WatchGame>.fromOpaque(context!).takeUnretainedValue()
            let current = text.map { String(cString: $0) } ?? ""
            let password = isPassword != 0

            // the watch shows its own login screen instead of the game's
            guard rsc_is_logged_in() != 0 else { return }

            DispatchQueue.main.async {
                game.textRequest = TextRequest(text: current, isPassword: password)
            }
        }

        config.on_menu = { context, count, items in
            let game = Unmanaged<WatchGame>.fromOpaque(context!).takeUnretainedValue()

            let texts = (0..<Int(count)).map { index -> String in
                items.flatMap { $0[index] }.map { String(cString: $0) } ?? ""
            }

            DispatchQueue.main.async {
                game.isMenuOpen = true
                game.menu = Menu(items: texts)
            }
        }

        config.on_message = { _, message, type in
            guard let message = message else { return }
            let text = String(cString: message)

            DispatchQueue.main.async {
                GameAlerts.shared.check(message: text, type: Int(type))
            }
        }

        config.on_hide_keyboard = { context in
            let game = Unmanaged<WatchGame>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { game.textRequest = nil }
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
            }
        }

        // a 2001Scape world needs the 2001 game's data, fetched once
        config.on_request_retro_data = { _, dataDirectory in
            guard let dataDirectory = dataDirectory else { return }
            let directory = URL(fileURLWithPath: String(cString: dataDirectory))

            DispatchQueue.main.async {
                RetroData.download(into: directory) { success in
                    rsc_retro_data_ready(success ? 1 : 0)
                }
            }
        }

        rsc_set_watch_ui(1)
        GameAlerts.shared.start()

        // before the game reads options.ini
        WatchSync.shared.removeStoredPasswords()

        cacheDirectory.path.withCString { cachePath in
            WatchSync.shared.configDirectory.path.withCString { configPath in
                RetroData.directory.path.withCString { dataPath in
                    config.cache_dir = cachePath
                    config.config_dir = configPath
                    config.data_dir = dataPath
                    rsc_start(&config)
                }
            }
        }

        message = nil

        #if targetEnvironment(simulator)
        startSimulatorTest()
        #endif

        // the client draws about 50 frames a second; 30 is plenty to show
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // nothing to draw while watching the iPhone
            if self.phoneStatus == nil {
                self.updateFrame()
            }
            self.updateStatus()
            self.updateLogin()
        }
    }

    /// The watch's account screen is covering the game.
    var showsAccountScreen: Bool {
        isGameStarted && phoneStatus == nil && !status.isLoggedIn && login.isAccountScreen
    }

    /// frames drawn since the account screen came up
    private var coveredFrames = 0

    private func updateFrame() {
        // nothing to show under the account screen, except the logo once the
        // game has drawn its login screen
        if showsAccountScreen {
            coveredFrames += 1
            guard logo == nil, coveredFrames > 5 else { return }
        } else {
            coveredFrames = 0
        }

        var pixels: UnsafePointer<UInt32>?
        var width: Int32 = 0
        var height: Int32 = 0

        let serial = rsc_frame_lock(&pixels, &width, &height)

        guard serial != lastSerial, let pixels = pixels, width > 0, height > 0 else {
            rsc_frame_unlock()
            return
        }

        let data = Data(bytes: pixels, count: Int(width) * Int(height) * 4)
        rsc_frame_unlock()
        lastSerial = serial

        // 0x00RRGGBB little endian: blue, green, red, then an unused byte
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue)

        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: Int(width), height: Int(height),
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * 4,
                space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        if showsAccountScreen {
            logo = image.cropping(to: CGRect(
                x: 0, y: login.logoY, width: image.width, height: login.logoHeight))
        } else {
            frame = image
        }
    }

    private func updateStatus() {
        let status = GameStatus.current()

        if status != self.status {
            GameAlerts.shared.check(status)

            if status.isLoggedIn {
                loggingInAs = nil
                loginError = nil
            }

            // closing a tab puts the icons away again
            if self.status.isTabOpen && !status.isTabOpen {
                setTabsRevealed(false)
            }

            self.status = status
        }
    }

    // MARK: - Input

    /// Shows the ui tab icons for a few seconds (or while a tab is open).
    func revealTabs() {
        setTabsRevealed(true)

        hideTabsWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.status.isTabOpen else { return }
            self.setTabsRevealed(false)
        }

        hideTabsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func setTabsRevealed(_ revealed: Bool) {
        guard revealed != areTabsRevealed else { return }
        areTabsRevealed = revealed
        rsc_set_ui_tabs_revealed(revealed ? 1 : 0)
    }

    /// Picks a menu item, or closes the menu with nil.
    /// Checks each link to the game server after a login couldn't connect.
    /// The game retries logins by itself, so an open report is just updated.
    func checkRelay(host: String, port: Int) {
        guard let settings = WatchSync.shared.relaySettings, let route = relay?.route else { return }

        // through the address that answers now, as the game would connect
        route.forget()
        route.choose { base in
            RelayCheck.run(
                baseURL: base, token: settings.token,
                client: RelayCheck.clientName(settings.device), host: host, port: port,
                isWatch: true, route: route
            ) { [weak self] steps in
                self?.relayProblem = RelayProblem(steps: steps, host: host, port: port)
            }
        }
    }

    func chooseMenuItem(_ index: Int?) {
        // the sheet clears menu itself when it's swiped away, so whether the
        // game still waits for an answer is kept separately
        guard isMenuOpen else { return }
        isMenuOpen = false
        menu = nil
        rsc_choose_menu_item(Int32(index ?? -1))
    }

    func setCombatStyle(_ style: Int) {
        rsc_set_combat_style(Int32(style))
    }

    func setBackground(_ isBackground: Bool) {
        rsc_set_background(isBackground ? 1 : 0)
        GameAlerts.shared.isActive = !isBackground
    }

    /// Types text into the focused game field and presses enter.
    func submit(_ text: String) {
        let ascii = String(text.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
            .map(Character.init))

        if !ascii.isEmpty {
            rsc_text(ascii)
        }

        rsc_key(RSC_KEY_ENTER)
        textRequest = nil
    }
}
