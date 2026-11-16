import SwiftUI

/// The watch's login screen, in place of the game's (too small to tap, and
/// with no way to type a password): the saved accounts as large RSC-style
/// buttons that log in with a tap. The iPhone's accounts come from it
/// (AccountStore); ones added here stay on the watch.
struct AccountScreen: View {
    @ObservedObject var game: WatchGame
    @State private var isAdding = false

    private var phoneAccounts: [SavedAccount] { game.accounts.filter { $0.isFromPhone } }
    private var watchAccounts: [SavedAccount] { game.accounts.filter { !$0.isFromPhone } }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)

            if let name = game.loggingInAs {
                HStack(spacing: 8) {
                    ProgressView()
                        .frame(width: 24, height: 24)
                    Text("Logging in as \(name)…")
                        .font(.system(size: 15, weight: .semibold))
                }
                .listRowBackground(Color.clear)
            } else if let error = game.loginError {
                Text(error)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(RSC.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
            }

            if game.accounts.isEmpty {
                Text(game.isFetchingAccounts
                     ? "Getting accounts from your iPhone…"
                     : "Log in on your iPhone and its accounts appear here, or add one below.")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
            }

            if !phoneAccounts.isEmpty {
                Section(header: sectionTitle("From iPhone")) {
                    ForEach(phoneAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                }
            }

            if !watchAccounts.isEmpty {
                Section(header: sectionTitle("On this watch")) {
                    ForEach(watchAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                    .onDelete { offsets in
                        offsets.map { watchAccounts[$0] }.forEach(game.removeAccount)
                    }
                }
            }

            Section {
                rscButton(action: { isAdding = true }) {
                    Label("Add account", systemImage: "plus")
                }

                rscButton(action: { game.watchPhoneNow() }) {
                    Label("Watch iPhone", systemImage: "iphone")
                }

                rscButton(action: { game.showWorlds() }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Worlds")
                        if !game.login.worldName.isEmpty {
                            Text(game.login.worldName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(RSC.subtitle)
                        }
                    }
                }

                rscButton(action: { game.showOptions() }) {
                    Text("Options")
                }
            }
        }
        .listStyle(PlainListStyle())
        .disabled(game.loggingInAs != nil)
        .sheet(isPresented: $isAdding) {
            AddAccountView(game: game, isShown: $isAdding)
        }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 4) {
            if let logo = game.logo {
                Image(decorative: logo, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            Text("Welcome to RuneScape Classic")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(RSC.cyan)
    }

    private func accountRow(_ account: SavedAccount) -> some View {
        rscButton(action: { game.logIn(account) }) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.username)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(account.worldName.isEmpty ? account.host : account.worldName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(RSC.subtitle)
                    .lineLimit(1)
            }
        }
    }

    private func rscButton<Content: View>(
        action: @escaping () -> Void, @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 10)
        }
        .buttonStyle(RSCButtonStyle())
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
    }
}

/// Typing in a new account. It's saved on the watch once the server
/// accepts it.
struct AddAccountView: View {
    @ObservedObject var game: WatchGame
    @Binding var isShown: Bool

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Username", text: $username)
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textContentType(.password)

                Button(action: logIn) {
                    Text("Log in")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(RSCButtonStyle())
                .disabled(username.isEmpty || password.isEmpty)
                .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)

                Text(game.login.worldName.isEmpty
                     ? "Kept on this watch once it logs in."
                     : "On \(game.login.worldName) (change it in Worlds). Kept on this watch once it logs in.")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Add account")
        .onDisappear {
            password = ""
        }
    }

    private func logIn() {
        // as long as the game's own login boxes allow
        game.logIn(username: String(username.trimmingCharacters(in: .whitespaces).prefix(12)),
                   password: String(password.prefix(20)))
        password = ""
        isShown = false
    }
}

/// The game's colours.
enum RSC {
    static func rgb(_ hex: Int) -> Color {
        Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
              blue: Double(hex & 0xff) / 255)
    }

    /// panel.h: PANEL_BOX_TOP_COLOUR, PANEL_BOX_BOTTOM_COLOUR etc.
    static let boxTop = rgb(0x545d78)
    static let boxBottom = rgb(0x8792b3)
    static let boxTopLine = rgb(0x617097)
    static let boxBottomLine = rgb(0x586688)

    static let yellow = rgb(0xffff00)
    static let cyan = rgb(0x00ffff)
    static let subtitle = rgb(0x1e2232)
}

/// The game's bevelled button box (panel_draw_box), lighter while pressed.
struct RSCButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RSCBox())
            .overlay(Color.white.opacity(configuration.isPressed ? 0.25 : 0))
    }
}

struct RSCBox: View {
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [RSC.boxTop, RSC.boxBottom]),
            startPoint: .top, endPoint: .bottom)
            // thick light edges at the top and left, dark at the bottom and
            // right, with a thin line inside each
            .overlay(VStack(spacing: 0) {
                RSC.boxBottom.frame(height: 2)
                RSC.boxTopLine.frame(height: 1)
                Spacer(minLength: 0)
                RSC.boxBottomLine.frame(height: 1)
                RSC.boxTop.frame(height: 2)
            })
            .overlay(HStack(spacing: 0) {
                RSC.boxBottom.frame(width: 2)
                RSC.boxTopLine.frame(width: 1)
                Spacer(minLength: 0)
                RSC.boxBottomLine.frame(width: 1)
                RSC.boxTop.frame(width: 2)
            })
    }
}
