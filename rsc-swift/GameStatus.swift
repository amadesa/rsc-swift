import Foundation

/// The player's state from the game (rsc_get_status), for the watch's
/// overlay and for GameAlerts.
struct GameStatus: Equatable {
    var isLoggedIn = false
    var hits = 0
    var maxHits = 0
    var prayer = 0
    var maxPrayer = 0
    /// 0 to 750
    var fatigue = 0
    var combatStyle = 0
    var isTabOpen = false
    var isWindowOpen = false
    var inventoryCount = 0
    var isDead = false
    /// until the client logs out for not being touched, or -1
    var idleLogoutSeconds = -1
    /// the account logged in to
    var username = ""

    static func current() -> GameStatus {
        var status = RscStatus()
        rsc_get_status(&status)

        let username = withUnsafeBytes(of: status.username) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }

        return GameStatus(
            isLoggedIn: status.logged_in != 0,
            hits: Int(status.hits), maxHits: Int(status.max_hits),
            prayer: Int(status.prayer), maxPrayer: Int(status.max_prayer),
            fatigue: Int(status.fatigue), combatStyle: Int(status.combat_style),
            isTabOpen: status.ui_tab != 0, isWindowOpen: status.window_open != 0,
            inventoryCount: Int(status.inventory_count), isDead: status.dead != 0,
            idleLogoutSeconds: Int(status.idle_logout_seconds), username: username)
    }
}

// MARK: - Sending to the watch

/// The iPhone tells the watch app about its game over WatchConnectivity
/// messages (PhoneWatchSync -> WatchSync), so the watch can tap for the
/// iPhone's alerts and show its stats while the iPhone is in use, when iOS
/// keeps notifications on the iPhone.
enum CompanionMessage {
    static let kind = "kind"
    /// [kind: status, status: GameStatus.dictionary]
    static let status = "status"
    /// [kind: alert, alert: GameAlert raw value, title, body, urgent]
    static let alert = "alert"
    /// [kind: query] -> reply [status: GameStatus.dictionary, alerts: [alert
    /// messages the watch couldn't be sent]]. The watch asks every few
    /// seconds, as the iPhone can't message it while the wrist is down.
    static let query = "query"
    static let alerts = "alerts"
    /// [kind: accountsQuery] -> reply [accounts: the SavedAccounts the
    /// watch may have, as JSON], or [:] if the iPhone can't read them
    static let accountsQuery = "accounts_query"
    /// [kind: accounts, accounts: as above], sent when they change while
    /// the watch app is open
    static let accounts = "accounts"
    /// in the application context: the ids of the accounts the watch may
    /// keep (no passwords, see AccountStore.idsForWatch)
    static let accountIDs = "account_ids"
    /// [kind: relay, method, path ("v1/..."), query, headers, body] -> reply
    /// [status, headers, body] or [error]: a request to rsc-relay that the
    /// iPhone sends on, when the watch can't reach the relay itself
    /// (RelayRoute's route through the iPhone)
    static let relay = "relay"
}

extension GameStatus {
    /// Whether two usernames are the same account: the server ignores case,
    /// and spaces and underscores are the same.
    static func isSameAccount(_ a: String, _ b: String) -> Bool {
        func normalized(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return normalized(a) == normalized(b)
    }

    /// What the watch shows of the iPhone's game.
    var dictionary: [String: Any] {
        [
            "logged_in": isLoggedIn, "hits": hits, "max_hits": maxHits,
            "prayer": prayer, "max_prayer": maxPrayer, "fatigue": fatigue,
            "combat_style": combatStyle, "username": username,
        ]
    }

    init(dictionary: [String: Any]) {
        self.init()
        isLoggedIn = dictionary["logged_in"] as? Bool ?? false
        hits = dictionary["hits"] as? Int ?? 0
        maxHits = dictionary["max_hits"] as? Int ?? 0
        prayer = dictionary["prayer"] as? Int ?? 0
        maxPrayer = dictionary["max_prayer"] as? Int ?? 0
        fatigue = dictionary["fatigue"] as? Int ?? 0
        combatStyle = dictionary["combat_style"] as? Int ?? 0
        username = dictionary["username"] as? String ?? ""
    }
}
