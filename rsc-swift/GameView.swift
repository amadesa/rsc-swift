import UIKit

/// Displays the game and forwards touches and on-screen keyboard input to it.
final class GameView: UIView {
    private let display = makeFrameDisplay()
    private let inputPreview = InputPreviewBar()
    // separate fields so only the game's password box offers password
    // AutoFill (see KeyboardProxyField)
    private let textProxy = KeyboardProxyField(isPassword: false)
    private let passwordProxy = KeyboardProxyField(isPassword: true)
    private var activeProxy: KeyboardProxyField?
    private let worldList = WorldListScroller()

    /// True while the game has a text field focused.
    private(set) var isTyping = false

    /// Stops drawing, e.g. while the app is in the background.
    var isPaused: Bool {
        get { display.isPaused }
        set { display.isPaused = newValue }
    }

    init() {
        super.init(frame: .zero)

        backgroundColor = .black
        isMultipleTouchEnabled = true

        // touches land on this view; the display only draws
        display.frame = bounds
        display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(display)

        inputPreview.onDone = { [weak self] in self?.stopTyping() }

        textProxy.delegate = self
        passwordProxy.delegate = self
        addSubview(textProxy)

        worldList.isHidden = true
        addSubview(worldList)
    }

    /// Shows the native scrolling over the Worlds screen's list while it's
    /// up. Called a few times a second.
    func updateWorldList(_ state: RscLoginState, isLoggedIn: Bool) {
        let isShowing = state.ready != 0 && !isLoggedIn
            && state.screen == RSC_LOGIN_SCREEN_WORLDS.rawValue && state.options_open == 0
            && state.world_list_height > 0 && state.frame_width > 0 && state.frame_height > 0

        worldList.isHidden = !isShowing
        if isShowing {
            worldList.update(state, in: bounds.size)
        }
    }

    required init?(coder: NSCoder) {
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

        let proxy = isPassword ? passwordProxy : textProxy

        // the password field is only in the view while it's used: iOS treats
        // other text fields near a password field as username fields and
        // offers saved passwords on them too
        if proxy.superview == nil {
            addSubview(proxy)
        }

        // mirror the game's field so the keyboard has something to delete
        proxy.text = text
        inputPreview.set(text: text, isPassword: isPassword)

        if activeProxy !== proxy {
            // the accessory bar can only belong to one field at a time
            activeProxy?.inputAccessoryView = nil
            proxy.inputAccessoryView = inputPreview
            activeProxy = proxy
        }

        if proxy.isFirstResponder {
            proxy.reloadInputViews()
        } else {
            proxy.becomeFirstResponder()
        }

        if !isPassword {
            passwordProxy.removeFromSuperview()
        }
    }

    func stopTyping() {
        isTyping = false
        activeProxy?.resignFirstResponder()
        passwordProxy.removeFromSuperview()
    }
}

/// Makes the Worlds screen's list scroll like any iOS list: momentum,
/// rubber-banding, flicking. The game still draws it in its own font and
/// colours (worldlist_draw_scrolling); this transparent scroll view over it
/// only tracks the finger and tells the game how far it has scrolled, and
/// turns taps into choosing a world.
private final class WorldListScroller: UIScrollView, UIScrollViewDelegate {
    /// frame pixels to points
    private var scale: CGFloat = 1
    private var rowHeight: CGFloat = 18
    private var count = 0
    private var selected = -1
    /// the frame position and size of the list, to notice a rebuilt layout
    private var layout: [Int32] = []

    init() {
        super.init(frame: .zero)

        backgroundColor = .clear
        showsVerticalScrollIndicator = false // the game draws its own
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        delegate = self
        if #available(iOS 11.0, *) {
            contentInsetAdjustmentBehavior = .never
        }

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ state: RscLoginState, in viewSize: CGSize) {
        let newLayout = [state.frame_width, state.frame_height, state.world_list_x,
                         state.world_list_y, state.world_list_width, state.world_list_height]

        if newLayout != layout || Int(state.world_count) != count {
            layout = newLayout
            scale = viewSize.width / CGFloat(state.frame_width)
            rowHeight = CGFloat(state.world_list_row_height)
            count = Int(state.world_count)

            frame = CGRect(
                x: CGFloat(state.world_list_x) * scale, y: CGFloat(state.world_list_y) * scale,
                width: CGFloat(state.world_list_width) * scale,
                height: CGFloat(state.world_list_height) * scale)
            contentSize = CGSize(width: frame.width, height: CGFloat(count) * rowHeight * scale)

            // keep the offset in range, e.g. after removing a world
            let maxOffset = max(0, contentSize.height - frame.height)
            if contentOffset.y > maxOffset {
                contentOffset.y = maxOffset
            }
        }

        // bring a newly selected world (just added, or restored) into view
        let newSelected = Int(state.world_selected)
        if newSelected != selected {
            selected = newSelected
            if selected >= 0 && !isTracking && !isDecelerating {
                let row = CGRect(x: 0, y: CGFloat(selected) * rowHeight * scale,
                                 width: frame.width, height: rowHeight * scale)
                scrollRectToVisible(row, animated: true)
            }
        }

        sendOffset()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        sendOffset()
    }

    private func sendOffset() {
        rsc_set_world_list_scroll(Float(contentOffset.y / scale))
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self) // in content, so offset included
        let scrollbarWidth = 14 * scale

        // the game's scrollbar arrows step a row, as they always did
        if contentSize.height > bounds.height && point.x > bounds.width - scrollbarWidth {
            let y = point.y - contentOffset.y
            let step = rowHeight * scale
            let maxOffset = contentSize.height - bounds.height
            if y < 12 * scale {
                setContentOffset(CGPoint(x: 0, y: max(0, contentOffset.y - step)), animated: true)
            } else if y > bounds.height - 12 * scale {
                setContentOffset(CGPoint(x: 0, y: min(maxOffset, contentOffset.y + step)), animated: true)
            }
            return
        }

        let row = Int(point.y / (rowHeight * scale))
        if row >= 0 && row < count {
            rsc_choose_world(Int32(row))
        }
    }

    // touches here are the list's alone; without these UIView would pass
    // them on to the game view as taps on the game
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

/// The on-screen keyboard types into this invisible text field rather than
/// into the game view directly, so it behaves like any other text field:
/// holding delete repeats (and speeds up to whole words) and paste works.
/// Every edit is forwarded to the game as backspaces and characters.
///
/// Password AutoFill remembers a field once it has been secure, so a single
/// field toggled between the login password and chat kept offering saved
/// passwords in chat. The password box gets its own field instead.
private final class KeyboardProxyField: UITextField {
    init(isPassword: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

        isSecureTextEntry = isPassword
        // only the password box offers password AutoFill (iOS 11+)
        if #available(iOS 11.0, *) {
            textContentType = isPassword ? .password : nil
        }

        // must stay visible and interactive to become first responder, so
        // make it nearly transparent and let touches fall through instead
        alpha = 0.01

        // the client only understands ASCII and must see each keystroke as
        // typed, so turn off every kind of autocorrection
        keyboardType = .asciiCapable
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        if #available(iOS 11.0, *) {
            smartQuotesType = .no
            smartDashesType = .no
            smartInsertDeleteType = .no
        }
        returnKeyType = .done

        accessibilityIdentifier = isPassword ? "passwordProxy" : "keyboardProxy"
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
            label.leadingAnchor.constraint(equalTo: safeEdges.leading, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            done.trailingAnchor.constraint(equalTo: safeEdges.trailing, constant: -16),
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

/// The edges to keep content within: the safe area on iOS 11 and later, and
/// the view's own edges before that (those devices have no notch or home
/// indicator to avoid).
struct SafeEdges {
    let leading: NSLayoutXAxisAnchor
    let trailing: NSLayoutXAxisAnchor
    let top: NSLayoutYAxisAnchor
    let bottom: NSLayoutYAxisAnchor
}

extension UIView {
    var safeEdges: SafeEdges {
        if #available(iOS 11.0, *) {
            let guide = safeAreaLayoutGuide
            return SafeEdges(
                leading: guide.leadingAnchor, trailing: guide.trailingAnchor,
                top: guide.topAnchor, bottom: guide.bottomAnchor)
        }

        return SafeEdges(
            leading: leadingAnchor, trailing: trailingAnchor,
            top: topAnchor, bottom: bottomAnchor)
    }
}
