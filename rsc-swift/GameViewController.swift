import UIKit

final class GameViewController: UIViewController {
    private let gameView = GameView()
    private var gameSize: (width: Int, height: Int)?
    private lazy var addWorld = AddWorldController(presenter: self) { world in
        GameClient.shared.add(world)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        gameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gameView)

        // keep the game's edge UI (tabs, chat) clear of the notch and corners
        let safeArea = view.safeEdges
        NSLayoutConstraint.activate([
            gameView.leadingAnchor.constraint(equalTo: safeArea.leading),
            gameView.trailingAnchor.constraint(equalTo: safeArea.trailing),
            gameView.topAnchor.constraint(equalTo: safeArea.top),
            gameView.bottomAnchor.constraint(equalTo: safeArea.bottom),
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

        if let gameSize = gameSize, gameSize == size { return }
        gameSize = size

        if GameClient.shared.isStarted {
            GameClient.shared.resize(width: size.width, height: size.height)
        } else {
            GameClient.shared.start(width: size.width, height: size.height)
        }
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
