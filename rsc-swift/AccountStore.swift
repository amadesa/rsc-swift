import Foundation
import Security

/// A login the server accepted, kept for logging in again with a tap.
struct SavedAccount: Codable, Equatable {
    var username: String
    var password: String
    var worldName: String
    var host: String
    var port: Int
    /// on the iPhone: whether the watch gets a copy (on unless turned off)
    var sharesWithWatch: Bool
    /// on the watch: a copy of one of the iPhone's, rather than added here
    var isFromPhone: Bool
    var lastUsed: Date

    /// The same account on the same world has the same id.
    var id: String { Self.id(username: username, host: host, port: port) }

    static func id(username: String, host: String, port: Int) -> String {
        let name = username.lowercased().replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "\(name)@\(host):\(port)"
    }
}

/// The saved accounts, each one a keychain item, so passwords aren't kept
/// in options.ini. Items stay on this device: they aren't synced with iCloud
/// Keychain or restored from a backup to another device.
///
/// The iPhone's can be read once it's been unlocked after starting up, as
/// the game logs back in, and the watch asks for its copies, while the
/// iPhone is locked. The watch's can only be read while it's unlocked, which
/// is while it's on the wrist after the passcode.
final class AccountStore {
    static let shared = AccountStore()

    /// Posted on the main thread after the accounts change.
    static let didChange = Notification.Name("AccountStoreDidChange")

    private static let service = "rsc.accounts"

    private var accessibility: CFString {
        #if os(watchOS)
        return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
    }

    private init() {}

    /// Every account, most recently used first, or nil if the keychain
    /// can't be read right now (e.g. the device is locked).
    func all() -> [SavedAccount]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let items = result as? [Data] else { return nil }

        let decoder = JSONDecoder()
        return items.compactMap { try? decoder.decode(SavedAccount.self, from: $0) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Adds the account, or replaces the one with the same id.
    @discardableResult
    func save(_ account: SavedAccount) -> Bool {
        guard let data = try? JSONEncoder().encode(account) else { return false }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.id,
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]

        var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            let add = item.merging(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }

        return status == errSecSuccess
    }

    func remove(id: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
        ]

        SecItemDelete(item as CFDictionary)
    }

    /// Saves a login the server just accepted. A new account is shared
    /// with the watch; an existing one keeps its setting.
    func remember(
        username: String, password: String, worldName: String, host: String, port: Int,
        isFromPhone: Bool = false
    ) {
        let id = SavedAccount.id(username: username, host: host, port: port)
        let existing = all()?.first { $0.id == id }

        var account = existing ?? SavedAccount(
            username: username, password: password, worldName: worldName, host: host,
            port: port, sharesWithWatch: true, isFromPhone: isFromPhone, lastUsed: Date())

        account.username = username
        account.password = password
        account.lastUsed = Date()
        if !worldName.isEmpty {
            account.worldName = worldName
        }

        if save(account) {
            changed()
        }
    }

    func changed() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    // MARK: - Between the iPhone and the watch

    /// The iPhone's accounts the watch may have, for sending to it.
    func encodedForWatch() -> Data? {
        guard let accounts = all() else { return nil }
        return try? JSONEncoder().encode(accounts.filter { $0.sharesWithWatch })
    }

    /// The ids of the iPhone's accounts the watch may have. Unlike the
    /// accounts themselves, these can go in the application context, which
    /// is stored until the watch app runs, so turning sharing off or
    /// removing an account reaches the watch even when it's away.
    func idsForWatch() -> [String]? {
        all()?.filter { $0.sharesWithWatch }.map { $0.id }
    }

    /// On the watch: replaces its copies of the iPhone's accounts with
    /// these. Accounts added on the watch stay.
    func replacePhoneAccounts(with data: Data) {
        guard let accounts = try? JSONDecoder().decode([SavedAccount].self, from: data),
              let current = all()
        else { return }

        let ids = Set(accounts.map { $0.id })

        for old in current where old.isFromPhone && !ids.contains(old.id) {
            remove(id: old.id)
        }

        for var account in accounts {
            account.isFromPhone = true
            if let local = current.first(where: { $0.id == account.id }) {
                account.lastUsed = max(account.lastUsed, local.lastUsed)
            }
            save(account)
        }

        changed()
    }

    /// On the watch: removes copies of the iPhone's accounts that it no
    /// longer shares.
    func keepPhoneAccounts(ids: [String]) {
        guard let current = all() else { return }

        let ids = Set(ids)
        var isChanged = false

        for old in current where old.isFromPhone && !ids.contains(old.id) {
            remove(id: old.id)
            isChanged = true
        }

        if isChanged {
            changed()
        }
    }

    /// A setting's value in options.ini, e.g. "username".
    static func value(of key: String, in options: String) -> String? {
        for line in options.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// An options.ini with the remembered password left out: for the
    /// watch's copy, and for clearing the one older versions saved.
    static func removingPassword(from options: String) -> String {
        options.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let key = line.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces)
            return key == "password" ? "password = " : String(line)
        }.joined(separator: "\n")
    }
}
