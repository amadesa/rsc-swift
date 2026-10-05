import MetalKit
import UIKit

/// Displays the game and forwards touches and on-screen keyboard input to it.
final class GameView: MTKView {
    private var renderer: FrameRenderer?
    private let inputPreview = InputPreviewBar()
    private let keyboardProxy = KeyboardProxyField()

    /// True while the game has a text field focused.
    private(set) var isTyping = false

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = 60
        isMultipleTouchEnabled = true

        renderer = FrameRenderer(view: self)
        delegate = renderer

        inputPreview.onDone = { [weak self] in self?.stopTyping() }

        keyboardProxy.delegate = self
        keyboardProxy.inputAccessoryView = inputPreview
        addSubview(keyboardProxy)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Touch

    private func send(_ touches: Set<UITouch>, phase: RscTouchPhase) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        for touch in touches {
            let point = touch.location(in: self)
            // a UITouch object is stable for the lifetime of the touch
            let finger = Int(bitPattern: Unmanaged.passUnretained(touch).toOpaque())

            rsc_touch(
                phase, finger,
                Float(point.x / bounds.width), Float(point.y / bounds.height))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: RSC_TOUCH_DOWN)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: RSC_TOUCH_MOVE)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: RSC_TOUCH_UP)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: RSC_TOUCH_UP)
    }

    // MARK: - Keyboard

    func startTyping(text: String, isPassword: Bool) {
        isTyping = true

        // mirror the game's field so the keyboard has something to delete
        keyboardProxy.isSecureTextEntry = isPassword
        keyboardProxy.text = text
        inputPreview.set(text: text, isPassword: isPassword)

        if keyboardProxy.isFirstResponder {
            keyboardProxy.reloadInputViews()
        } else {
            keyboardProxy.becomeFirstResponder()
        }
    }

    func stopTyping() {
        isTyping = false
        keyboardProxy.resignFirstResponder()
    }
}

/// The on-screen keyboard types into this invisible text field rather than
/// into the game view directly, so it behaves like any other text field:
/// holding delete repeats (and speeds up to whole words) and paste works.
/// Every edit is forwarded to the game as backspaces and characters.
private final class KeyboardProxyField: UITextField {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

        // must stay visible and interactive to become first responder, so
        // make it nearly transparent and let touches fall through instead
        alpha = 0.01

        // the client only understands ASCII and must see each keystroke as
        // typed, so turn off every kind of autocorrection
        keyboardType = .asciiCapable
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .done

        accessibilityIdentifier = "keyboardProxy"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // touches belong to the game view underneath
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    // the game only edits at the end of its field, so keep the caret there
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        endOfDocument
    }

    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
}

extension GameView: UITextFieldDelegate {
    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        let current = (textField.text ?? "") as NSString

        // edits away from the end can't be mirrored by backspacing
        guard range.location + range.length == current.length else { return false }

        let ascii = String(string.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
            .map(Character.init))

        if !string.isEmpty && ascii.isEmpty {
            return false
        }

        for _ in 0..<range.length {
            rsc_key(RSC_KEY_BACKSPACE)
        }

        if !ascii.isEmpty {
            rsc_text(ascii)
        }

        let updated = current.replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: ascii)
        textField.text = updated
        inputPreview.set(text: updated, isPassword: textField.isSecureTextEntry)

        // we applied the (filtered) change ourselves
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        rsc_key(RSC_KEY_ENTER)
        textField.text = ""
        stopTyping()
        return false
    }
}

/// Sits above the keyboard and echoes what is being typed, since the
/// keyboard usually covers the game's own text field.
final class InputPreviewBar: UIView {
    var onDone: (() -> Void)?

    private let label = UILabel()
    private var text = ""
    private var isPassword = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))

        autoresizingMask = .flexibleWidth
        backgroundColor = UIColor(white: 0.1, alpha: 0.95)

        if #available(iOS 13.0, *) {
            label.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        } else {
            label.font = UIFont(name: "Menlo", size: 17)
        }
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .boldSystemFont(ofSize: 17)
        done.addTarget(self, action: #selector(donePressed), for: .touchUpInside)

        for view in [label, done] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        done.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func donePressed() {
        onDone?()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    func set(text: String, isPassword: Bool) {
        self.text = text
        self.isPassword = isPassword
        render()
    }

    private func render() {
        let shown = isPassword ? String(repeating: "•", count: text.count) : text
        label.text = shown + "▏"
    }
}
