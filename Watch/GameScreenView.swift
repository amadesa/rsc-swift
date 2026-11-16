import AVKit
import SwiftUI
import WatchKit

/// The game, full screen. Touches go to the client like on iPhone: tap to
/// click, hold for the right-click menu, drag to rotate the camera. Hits,
/// prayer, fatigue and the combat style are shown in watch style on top, and
/// turning the Digital Crown brings out the inventory, map etc. icons.
struct GameScreenView: View {
    @ObservedObject var game: WatchGame
    @ObservedObject private var keepAlive = KeepAlive.shared

    @State private var isTouching = false
    @State private var typed = ""
    @State private var crown = 0.0
    /// the crown's turn since it last changed a full screen tab
    @State private var crownTabTurn = 0.0
    @State private var lastCrown = 0.0
    @State private var isChoosingCombatStyle = false

    /// the game's combat styles, in its order, named by what they train
    static let combatStyles = ["Controlled", "Strength", "Attack", "Defense"]

    /// how far the crown turns to go to the next tab, in its rotation's units
    static let crownTabStep = 8.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .sheet(item: $game.menu, onDismiss: { game.chooseMenuItem(nil) }) { menu in
                        menuList(menu)
                    }

                // watchOS hides the clock while a video player is on screen.
                // kept tiny and disabled so it can't take any taps
                VideoPlayer(player: nil)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .disabled(true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if let phone = game.phoneStatus {
                    phoneView(phone)
                } else if game.showsAccountScreen {
                    AccountScreen(game: game)
                } else if let frame = game.frame {
                    Image(decorative: frame, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let message = game.message {
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .contentShape(Rectangle())
            // the game takes every touch; watching the iPhone or on the
            // account screen, the buttons do
            .gesture(touchGesture(in: geometry.size),
                     including: isGameShown ? .all : .subviews)
            .overlay(statusOverlay)
            .overlay(alertBanner, alignment: .top)
            .onAppear { game.start(screenSize: geometry.size) }
            .sheet(isPresented: $isChoosingCombatStyle) { combatStylePicker }
            .background(Color.clear.sheet(item: $game.relayProblem) { problem in
                relayReport(problem)
            })
        }
        .ignoresSafeArea()
        // the account screen's list scrolls with the crown instead
        .focusable(!game.showsAccountScreen)
        .digitalCrownRotation(
            $crown, from: -10_000, through: 10_000, by: 1,
            sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: game.menu?.id) { _ in
            // the menu opened under a held finger, which the sheet takes over
            if isTouching {
                rsc_touch(RSC_TOUCH_UP, 1, Float(game.lastTouch.x), Float(game.lastTouch.y))
                isTouching = false
            }
        }
        .onChange(of: crown) { value in
            let turn = value - lastCrown
            lastCrown = value

            guard game.status.isLoggedIn else { return }

            // a full screen tab panel: the crown goes through the tabs
            if game.status.isTabOpen && rsc_ui_tabs_full_screen() != 0 {
                crownTabTurn += turn

                if abs(crownTabTurn) >= Self.crownTabStep {
                    rsc_step_ui_tab(crownTabTurn > 0 ? 1 : -1)
                    crownTabTurn = 0
                    WKInterfaceDevice.current().play(.click)
                }
            } else {
                crownTabTurn = 0
                game.revealTabs()
            }
        }
        .sheet(item: $game.textRequest) { request in
            VStack {
                TextField(request.isPassword ? "Password" : "Type", text: $typed, onCommit: {
                    game.submit(typed)
                    typed = ""
                })
            }
            .onAppear { typed = "" }
        }
    }

    // MARK: - Watch UI

    /// The game is on screen, rather than the iPhone's stats or the account
    /// screen.
    private var isGameShown: Bool {
        game.phoneStatus == nil && !game.showsAccountScreen
    }

    /// The last alert's text, so a tap can be read with the wrist raised.
    @ViewBuilder
    private var alertBanner: some View {
        if let banner = game.alertBanner {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(banner.body)
                    .font(.system(size: 13))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.15).opacity(0.95)))
            .padding(.horizontal, 10)
            .padding(.top, 24)
            .onTapGesture { game.alertBanner = nil }
        }
    }

    /// Hits, prayer and fatigue at the bottom left; the combat style at the
    /// bottom right, making way for the tab icons when they're out.
    @ViewBuilder
    private var statusOverlay: some View {
        let status = game.status

        if status.isLoggedIn && !status.isWindowOpen && !status.isTabOpen {
            GeometryReader { geometry in
                let stats = Self.statsInsets(screenSize: geometry.size)

                ZStack(alignment: .bottomLeading) {
                    Color.clear

                    // against the left edge, as low as the screen's rounded
                    // corner allows
                    VStack(alignment: .leading, spacing: 0) {
                        statLine("Hits", "\(status.hits)/\(status.maxHits)",
                                 hitsColour(status))
                        statLine("Prayer", "\(status.prayer)/\(status.maxPrayer)",
                                 Color(red: 0.4, green: 0.85, blue: 1))
                        statLine("Fatigue", "\(status.fatigue * 100 / 750)%",
                                 status.fatigue >= 600 ? .orange : .white)
                    }
                    .allowsHitTesting(false)
                    .padding(.leading, stats.leading)
                    .padding(.bottom, stats.bottom)

                    if !game.areTabsRevealed {
                        Button(action: { isChoosingCombatStyle = true }) {
                            // on two lines, so it's narrow enough to stay
                            // clear of the stats on the left
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("Combat:")
                                Text(Self.combatStyles[min(max(status.combatStyle, 0), 3)])
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(PlainButtonStyle())
                        // level with the bottom of Fatigue, mirroring the
                        // stats against the right edge, above the corner
                        .padding(.trailing, stats.leading)
                        .padding(.bottom, stats.bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomTrailing)
                    }
                }
            }
            // measured from the screen's edges, not the safe area
            .ignoresSafeArea()
        }
    }

    /// How far in from the left edge the stats sit, and how far up they
    /// must then go for the bottom line to clear the screen's rounded
    /// corner.
    private static func statsInsets(screenSize: CGSize) -> (leading: CGFloat, bottom: CGFloat) {
        let leading: CGFloat = 4
        let radius = screenCornerRadius(screenSize: screenSize)

        guard radius > leading else { return (leading, 2) }

        // the corner's curve is `leading` in from the edge at this height
        let rest = radius - leading
        let bottom = radius - (radius * radius - rest * rest).squareRoot()

        return (leading, bottom.rounded(.up) + 1)
    }

    /// The display's corner radius in points. watchOS only says so
    /// privately, so this falls back to the shape of recent watches, whose
    /// corners are about a fifth of the screen's width.
    private static func screenCornerRadius(screenSize: CGSize) -> CGFloat {
        let device = WKInterfaceDevice.current()
        let key = "screenCornerRadius"

        if device.responds(to: NSSelectorFromString(key)),
           let radius = device.value(forKey: key) as? CGFloat, radius > 0 {
            return radius
        }

        return (screenSize.width * 0.19).rounded()
    }

    private func statLine(_ name: String, _ value: String, _ colour: Color) -> some View {
        (Text("\(name): ").foregroundColor(colour) + Text(value).foregroundColor(.white))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .shadow(color: .black, radius: 1, x: 1, y: 1)
    }

    private func hitsColour(_ status: WatchGame.Status) -> Color {
        guard status.maxHits > 0 else { return .green }
        let ratio = Double(status.hits) / Double(status.maxHits)
        return ratio <= 0.25 ? .red : ratio <= 0.5 ? .orange : .green
    }

    private func menuList(_ menu: WatchGame.Menu) -> some View {
        List {
            ForEach(0..<menu.items.count, id: \.self) { index in
                Button(action: { game.chooseMenuItem(index) }) {
                    colouredText(menu.items[index])
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .navigationTitle("Choose option")
    }

    /// The game's @col@ colour codes as coloured text.
    private func colouredText(_ string: String) -> Text {
        var result = Text("")
        var colour = Color.white
        var remaining = Substring(string)

        while !remaining.isEmpty {
            if remaining.hasPrefix("@"), remaining.count >= 5,
               remaining[remaining.index(remaining.startIndex, offsetBy: 4)] == "@" {
                let code = remaining.dropFirst().prefix(3)
                colour = Self.gameColours[String(code)] ?? colour
                remaining = remaining.dropFirst(5)
                continue
            }

            let end = remaining.dropFirst().firstIndex(of: "@") ?? remaining.endIndex
            result = result + Text(String(remaining[..<end])).foregroundColor(colour)
            remaining = remaining[end...]
        }

        return result
    }

    private static let gameColours: [String: Color] = {
        func rgb(_ hex: Int) -> Color {
            Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
        }

        return [
            "red": rgb(0xff0000), "lre": rgb(0xff9040), "yel": rgb(0xffff00),
            "gre": rgb(0x00ff00), "blu": rgb(0x6080ff), "cya": rgb(0x00ffff),
            "mag": rgb(0xff00ff), "whi": rgb(0xffffff), "bla": rgb(0xffffff),
            "dre": rgb(0xc00000), "ora": rgb(0xff9040), "ran": rgb(0xffffff),
            "or1": rgb(0xffb000), "or2": rgb(0xff7000), "or3": rgb(0xff3000),
            "gr1": rgb(0xc0ff00), "gr2": rgb(0x80ff00), "gr3": rgb(0x40ff00),
        ]
    }()

    private var combatStylePicker: some View {
        List {
            ForEach(0..<Self.combatStyles.count, id: \.self) { style in
                Button(action: {
                    game.setCombatStyle(style)
                    isChoosingCombatStyle = false
                }) {
                    HStack {
                        Text(Self.combatStyles[style])
                        Spacer()
                        if style == game.status.combatStyle {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Combat style")
    }

    // MARK: - Watching the iPhone game

    /// The iPhone game's stats; its alerts tap here while this stays open.
    private func phoneView(_ status: GameStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.username.isEmpty ? "Playing on iPhone" : "Playing on iPhone as \(status.username)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if status.isLoggedIn {
                bigStat("Hits", "\(status.hits)/\(status.maxHits)", hitsColour(status))
                bigStat("Prayer", "\(status.prayer)/\(status.maxPrayer)",
                        Color(red: 0.4, green: 0.85, blue: 1))
                bigStat("Fatigue", "\(status.fatigue * 100 / 750)%",
                        status.fatigue >= 600 ? .orange : .white)
                Text("Combat: \(Self.combatStyles[min(max(status.combatStyle, 0), 3)])")
                    .font(.footnote)
            } else {
                Text("Not logged in on the iPhone")
                    .font(.system(size: 16, weight: .semibold))
            }

            Spacer(minLength: 2)

            // watchOS only lets the app run in the background for an hour
            if let expiresAt = keepAlive.expiresAt {
                Text("Alerts until \(Self.timeFormatter.string(from: expiresAt))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Button(action: { game.playOnWatch() }) {
                Text("Play on watch")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private func bigStat(_ name: String, _ value: String, _ colour: Color) -> some View {
        (Text("\(name) ").foregroundColor(colour) + Text(value).foregroundColor(.white))
            .font(.system(size: 20, weight: .semibold).monospacedDigit())
    }

    // MARK: - Relay problems

    /// Each link from the watch to the game server, after a login couldn't
    /// get through the relay.
    private func relayReport(_ problem: WatchGame.RelayProblem) -> some View {
        List {
            ForEach(problem.steps, id: \.link) { step in
                relayStepRow(step)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Settings from iPhone")
                    .font(.system(size: 15, weight: .semibold))
                Text(syncedText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Button(action: { game.checkRelay(host: problem.host, port: problem.port) }) {
                Text("Check again")
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Can't connect")
    }

    private func relayStepRow(_ step: RelayCheck.Step) -> some View {
        let symbol: String
        let colour: Color
        var lines: [String] = []

        switch step.outcome {
        case .passed(let detail):
            symbol = "checkmark.circle.fill"
            colour = .green
            lines = detail.map { [$0] } ?? []
        case .failed(let failure):
            symbol = "xmark.circle.fill"
            colour = .red
            lines = [failure.title, failure.advice]
        case .notChecked:
            symbol = "minus.circle"
            colour = .gray
        }

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundColor(colour)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.link.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(colour == .gray ? .secondary : .primary)

                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var syncedText: String {
        let host = WatchSync.shared.relayHost.map { "Relay \($0). " } ?? ""

        guard let date = WatchSync.shared.lastSynced else {
            return host + "Open RSC on the iPhone to send them."
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return host + "Sent " + formatter.localizedString(for: date, relativeTo: Date()) + "."
    }

    /// Where the game picture sits within the view (it's letterboxed).
    private func frameRect(in size: CGSize) -> CGRect {
        guard let frame = game.frame else { return CGRect(origin: .zero, size: size) }

        let imageSize = CGSize(width: frame.width, height: frame.height)
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2,
            width: shown.width, height: shown.height)
    }

    private func touchGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // a menu opened under this finger has already ended the touch
                guard game.menu == nil else { return }
                send(isTouching ? RSC_TOUCH_MOVE : RSC_TOUCH_DOWN, value.location, in: size)
                isTouching = true
            }
            .onEnded { value in
                guard isTouching else { return }
                send(RSC_TOUCH_UP, value.location, in: size)
                isTouching = false
            }
    }

    private func send(_ phase: RscTouchPhase, _ point: CGPoint, in size: CGSize) {
        let rect = frameRect(in: size)
        guard rect.width > 0, rect.height > 0 else { return }

        let x = Float(min(max((point.x - rect.minX) / rect.width, 0), 1))
        let y = Float(min(max((point.y - rect.minY) / rect.height, 0), 1))

        game.lastTouch = CGPoint(x: CGFloat(x), y: CGFloat(y))

        // a watch has one finger
        rsc_touch(phase, 1, x, y)
    }
}
