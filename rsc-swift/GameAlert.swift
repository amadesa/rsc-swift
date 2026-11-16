import Foundation

/// The alerts GameAlerts gives on the iPhone and the Apple Watch. Each can be
/// turned on or off in the iPhone's Settings > RSC > Alerts, which
/// PhoneWatchSync also sends to the watch.
enum GameAlert: String, CaseIterable {
    case lowHits = "alert_hits_20"
    case veryLowHits = "alert_hits_10"
    case sameSpot = "alert_same_spot"
    case fatigue = "alert_fatigue"
    case idleLogout = "alert_idle_logout"
    case loggedOut = "alert_logged_out"
    case death = "alert_death"
    case inventoryFull = "alert_inventory_full"
    case levelUp = "alert_level_up"
    case messages = "alert_messages"

    /// on unless turned off in Settings (matches Settings.bundle)
    var isOnByDefault: Bool {
        switch self {
        case .lowHits, .veryLowHits, .sameSpot, .fatigue, .idleLogout, .loggedOut:
            return true
        case .death, .inventoryFull, .levelUp, .messages:
            return false
        }
    }

    func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: rawValue) as? Bool ?? isOnByDefault
    }
}
