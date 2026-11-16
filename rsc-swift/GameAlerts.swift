import Foundation
import UserNotifications
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// Taps or buzzes when something needs attention: low hits, fatigue, being
/// about to be logged out and so on. While the game is on screen it's just a
/// tap (a haptic on the watch, a vibration on the iPhone); in the background
/// it's a notification, which says what happened. iOS shows the iPhone's
/// notifications on a paired Apple Watch while the iPhone is locked.
///
/// Each alert fires once when its threshold is crossed and re-arms after
/// recovering, so hits wobbling around 20% don't keep buzzing.
final class GameAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GameAlerts()

    /// whether the game is on screen (set from the scene phase)
    var isActive = true

    /// also given every alert that fires (the iPhone sends them to the watch)
    var forward: ((GameAlert, String, String, Bool) -> Void)?

    /// given the title and text of every alert, for showing in the app
    var show: ((String, String) -> Void)?

    private var last = GameStatus()
    private var isStarted = false
    private var isLowHitsArmed = true
    private var isVeryLowHitsArmed = true
    private var isFatigue95Armed = true
    private var isFatigue100Armed = true
    private var isIdleArmed = true

    /// Asks once for permission to show notifications.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Checks

    /// Called with each new status from the game.
    func check(_ status: GameStatus) {
        defer { last = status }

        if last.isLoggedIn && !status.isLoggedIn {
            // logging out on purpose happens with the game on screen
            if !isActive {
                fire(.loggedOut, "Logged out", "You're no longer logged in to RuneScape.")
            }
            return
        }

        guard status.isLoggedIn else { return }

        if !last.isLoggedIn {
            // a fresh login: alert only on what changes from here
            rearmAll()
        }

        checkHits(status)
        checkFatigue(status)
        checkIdle(status)

        if status.isDead && !last.isDead {
            fire(.death, "You died", "Oh dear, you are dead!")
            rearmAll()
        }

        if status.inventoryCount >= 30 && last.inventoryCount < 30 && last.isLoggedIn {
            fire(.inventoryFull, "Inventory full", "Your inventory is full.")
        }
    }

    private func checkHits(_ status: GameStatus) {
        guard status.maxHits > 0 else { return }

        let percent = status.hits * 100 / status.maxHits
        let hits = "Hits \(status.hits)/\(status.maxHits)"

        if percent < 10 && isVeryLowHitsArmed {
            isVeryLowHitsArmed = false
            isLowHitsArmed = false
            fire(.veryLowHits, "Hits below 10%", hits, isUrgent: true)
        } else if percent < 20 && isLowHitsArmed {
            isLowHitsArmed = false
            fire(.lowHits, "Hits below 20%", hits)
        }

        if percent >= 15 { isVeryLowHitsArmed = true }
        if percent >= 25 { isLowHitsArmed = true }
    }

    private func checkFatigue(_ status: GameStatus) {
        let percent = status.fatigue * 100 / 750

        if percent >= 100 && isFatigue100Armed {
            isFatigue100Armed = false
            isFatigue95Armed = false
            fire(.fatigue, "Fatigue 100%", "Too tired to gain experience. Time to sleep.")
        } else if percent >= 95 && isFatigue95Armed {
            isFatigue95Armed = false
            fire(.fatigue, "Fatigue 95%", "Almost too tired to gain experience.")
        }

        // re-armed after sleeping
        if percent < 90 {
            isFatigue95Armed = true
            isFatigue100Armed = true
        }
    }

    private func checkIdle(_ status: GameStatus) {
        let seconds = status.idleLogoutSeconds

        if seconds >= 0 && seconds <= 15 && isIdleArmed {
            isIdleArmed = false
            fire(.idleLogout, "Idle logout soon",
                 "Logging out in \(seconds) seconds. Tap the game to stay logged in.")
        }

        if seconds < 0 || seconds > 20 {
            isIdleArmed = true
        }
    }

    /// Called with each message the game shows.
    func check(message: String, type: Int) {
        let text = Self.plain(message)

        if text.contains("You have been standing here for") {
            fire(.sameSpot, "Move to a new area",
                 "You've been standing in one spot too long. Move within a minute or you'll be logged out.")
        } else if text.contains("You just advanced") {
            fire(.levelUp, "Level up", text)
        } else if type == 6 && text.contains("tells you") {
            fire(.messages, "Private message", text)
        } else if text.contains("wishes to trade with you") {
            fire(.messages, "Trade request", text)
        } else if text.contains("wishes to duel with you") {
            fire(.messages, "Duel request", text)
        }
    }

    private func rearmAll() {
        isLowHitsArmed = true
        isVeryLowHitsArmed = true
        isFatigue95Armed = true
        isFatigue100Armed = true
        isIdleArmed = true
    }

    // MARK: - Delivery

    /// iOS is about to suspend the app, which stops the game; the server logs
    /// the player out about 30 seconds later.
    func appWillSuspend() {
        guard last.isLoggedIn else { return }
        fire(.loggedOut, "RSC paused",
             "iOS stopped RSC in the background, so you'll be logged out shortly. Open RSC to reconnect.")
    }

    /// Taps or notifies now. The watch also calls this for the iPhone's alerts.
    func fire(_ alert: GameAlert, _ title: String, _ body: String, isUrgent: Bool = false) {
        guard alert.isOn() else { return }

        forward?(alert, title, body, isUrgent)
        show?(title, body)

        if isActive {
            tap(isUrgent: isUrgent)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "rsc"

        // a newer alert of the same kind replaces the old one
        let request = UNNotificationRequest(identifier: alert.rawValue, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        if isUrgent {
            tap(isUrgent: true)
        }
    }

    private func tap(isUrgent: Bool) {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()

        guard isUrgent else {
            device.play(.notification)
            return
        }

        // three strong taps, hard to miss
        for index in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.6) {
                device.play(.failure)
            }
        }
        #else
        let generator = UINotificationFeedbackGenerator()

        guard isUrgent else {
            generator.notificationOccurred(.warning)
            return
        }

        for index in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.6) {
                generator.notificationOccurred(.error)
            }
        }
        #endif
    }

    /// Notifications arriving while the app is frontmost still show, as the
    /// wrist may be down or the phone put aside.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, watchOS 7.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    /// The text without the game's @col@ colour codes.
    static func plain(_ message: String) -> String {
        var text = message
        while let range = text.range(of: "@[a-z0-9]{3}@", options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
