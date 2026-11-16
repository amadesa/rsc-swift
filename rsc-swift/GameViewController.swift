import UIKit

final class GameViewController: UIViewController {
    private let gameView = GameView()
    private var gameSize: (width: Int, height: Int)?
    private var safeInsets: [Int] = []
    private var loginStateTimer: Timer?
    private lazy var addWorld = AddWorldController(presenter: self) { world in
        GameClient.shared.add(world)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        gameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gameView)

        // the 3D view fills the screen, into the corners and around the
        // Dynamic Island; the game keeps its controls clear of them
        // (rsc_set_safe_insets)
        NSLayoutConstraint.activate([
            gameView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gameView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gameView.topAnchor.constraint(equalTo: view.topAnchor),
            gameView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        GameClient.shared.onKeyboardRequest = { [weak self] text, isPassword in
            self?.gameView.startTyping(text: text, isPassword: isPassword)
        }

        GameClient.shared.onHideKeyboard = { [weak self] in
            self?.gameView.stopTyping()
        }

        GameClient.shared.onWorldRequest = { [weak self] in
            self?.addWorld.present()
        }

        GameClient.shared.onRemoveWorldRequest = { [weak self] index, name in
            self?.confirmRemoveWorld(at: index, name: name)
        }

        GameClient.shared.onRegister = { [weak self] name, url in
            self?.register(worldName: name, url: url)
        }

        GameClient.shared.onAccountsRequest = { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            AccountsController.present(from: self) { account in
                GameClient.shared.logIn(account)
            }
        }

        GameClient.shared.onRelayProblem = { [weak self] steps in
            self?.showRelayProblem(steps)
        }

        // the Worlds screen's list scrolls natively (GameView)
        loginStateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, GameClient.shared.isStarted else { return }
            var state = RscLoginState()
            rsc_get_login_state(&state)
            self.gameView.updateWorldList(state, isLoggedIn: GameClient.shared.isLoggedIn)
        }

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func didEnterBackground() {
        // iOS doesn't allow GPU work from the background
        gameView.isPaused = true
        GameClient.shared.enterBackground()
    }

    @objc private func willEnterForeground() {
        GameClient.shared.enterForeground()
        gameView.isPaused = false

        // apply any size change that was skipped while in the background
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let size = Self.gameSize(for: gameView.bounds.size)
        guard size.width > 0, size.height > 0 else { return }

        // while switching apps iOS lays the app out at other sizes for its
        // snapshots. resizing the game rebuilds its screens, so ignore those
        // and catch up when the app comes back
        if GameClient.shared.isStarted,
           UIApplication.shared.applicationState == .background {
            return
        }

        // the safe area in game pixels, rounded out so nothing is under it.
        // changing them lays the controls out again, like a resize
        let insets = Self.safeInsets(of: view, gameWidth: size.width)
        if insets != safeInsets {
            safeInsets = insets
            rsc_set_safe_insets(Int32(insets[0]), Int32(insets[1]), Int32(insets[2]),
                                Int32(insets[3]), Int32(insets[4]))
        }

        if let gameSize = gameSize, gameSize == size { return }
        gameSize = size

        if GameClient.shared.isStarted {
            GameClient.shared.resize(width: size.width, height: size.height)
        } else {
            GameClient.shared.start(width: size.width, height: size.height)
        }
    }

    /// What's wrong with the connection through rsc-relay, link by link.
    private func showRelayProblem(_ steps: [RelayCheck.Step]) {
        // the game retries logins on its own; one report is enough
        guard presentedViewController == nil else { return }

        let alert = UIAlertController(
            title: "Can't connect through the relay",
            message: "\n" + RelayCheck.report(steps), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        present(alert, animated: true)
    }

        private func confirmRemoveWorld(at index: Int, name: String) {
        let alert = UIAlertController(
            title: "Remove \(name)?",
            message: "You can add it again later with \"Add world\".",
            preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
            GameClient.shared.removeWorld(at: index)
        })

        present(alert, animated: true)
    }

    private func register(worldName: String, url: URL?) {
        if let url = url {
            UIApplication.shared.open(url)
            return
        }

        let alert = UIAlertController(
            title: "No registration page",
            message: "\(worldName) doesn't have a registration link. Create an account on the server's website, then tap Login. You can set a link when adding a world.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// The game renders at roughly one game pixel per point on phones, the
    /// same density as the web client in a mobile browser. Larger screens
    /// are scaled up so the fixed-size interface stays readable.
    static func gameSize(for viewSize: CGSize) -> (width: Int, height: Int) {
        let shortSide = min(viewSize.width, viewSize.height)
        let scale = max(1, shortSide / 400)

        return (Int((viewSize.width / scale).rounded()),
                Int((viewSize.height / scale).rounded()))
    }

    /// The view's safe area insets (top, left, bottom, right) and the
    /// screen's corner radius, in game pixels. None before iOS 11, which has
    /// no notch or home indicator.
    static func safeInsets(of view: UIView, gameWidth: Int) -> [Int] {
        guard #available(iOS 11.0, *), view.bounds.width > 0, gameWidth > 0 else {
            return [0, 0, 0, 0, 0]
        }

        let pixelsPerPoint = CGFloat(gameWidth) / view.bounds.width
        let insets = view.safeAreaInsets
        let radius = insets.bottom > 0 ? screenCornerRadius(view.window?.screen ?? UIScreen.main) : 0
        return [insets.top, insets.left, insets.bottom, insets.right, radius]
            .map { Int(($0 * pixelsPerPoint).rounded(.up)) }
    }

    /// How round the screen's corners are, in points, for keeping the
    /// status bars inside them. iOS only says privately; if it won't, the
    /// roundest iPhone's (the Pro Max models), which keeps them inside on
    /// any screen with a home indicator.
    private static func screenCornerRadius(_ screen: UIScreen) -> CGFloat {
        let key = "_displayCornerRadius"
        if screen.responds(to: NSSelectorFromString(key)),
           let radius = screen.value(forKey: key) as? CGFloat, radius > 0 {
            return radius
        }
        return 62
    }

    @available(iOS 11.0, *)
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override var prefersStatusBarHidden: Bool { true }
    @available(iOS 11.0, *)
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    @available(iOS 11.0, *)
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: - Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @available(iOS 13.4, *)
    private static func specialKey(_ usage: UIKeyboardHIDUsage) -> RscKey? {
        switch usage {
        case .keyboardLeftArrow: return RSC_KEY_LEFT
        case .keyboardRightArrow: return RSC_KEY_RIGHT
        case .keyboardUpArrow: return RSC_KEY_UP
        case .keyboardDownArrow: return RSC_KEY_DOWN
        case .keyboardPageUp: return RSC_KEY_PAGE_UP
        case .keyboardPageDown: return RSC_KEY_PAGE_DOWN
        case .keyboardHome: return RSC_KEY_HOME
        case .keyboardF1: return RSC_KEY_F1
        case .keyboardEscape: return RSC_KEY_ESCAPE
        default: return nil
        }
    }

    /// Keys that the software keyboard path already delivers while typing.
    @available(iOS 13.4, *)
    private static func textKey(_ usage: UIKeyboardHIDUsage) -> RscKey? {
        switch usage {
        case .keyboardReturnOrEnter, .keypadEnter: return RSC_KEY_ENTER
        case .keyboardDeleteOrBackspace: return RSC_KEY_BACKSPACE
        case .keyboardTab: return RSC_KEY_TAB
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard #available(iOS 13.4, *) else {
            super.pressesBegan(presses, with: event)
            return
        }

        var handled = false

        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command) else { continue }

            if let special = Self.specialKey(key.keyCode) {
                rsc_key_down(Int32(special.rawValue))
                handled = true
            } else if gameView.isTyping {
                // characters arrive through GameView's UIKeyInput instead
                continue
            } else if let textKey = Self.textKey(key.keyCode) {
                rsc_key_down(Int32(textKey.rawValue))
                handled = true
            } else if !key.characters.isEmpty, key.characters.allSatisfy(\.isASCII) {
                rsc_text(key.characters)
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard #available(iOS 13.4, *) else {
            super.pressesEnded(presses, with: event)
            return
        }

        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if let code = Self.specialKey(key.keyCode) ?? Self.textKey(key.keyCode) {
                rsc_key_up(Int32(code.rawValue))
                handled = true
            }
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}
