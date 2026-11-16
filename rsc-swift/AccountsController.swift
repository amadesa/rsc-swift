import UIKit

/// "Accounts" on the welcome screen: the logins saved on this iPhone. Tap
/// one to log in with it, turn its switch off to keep it off the Apple
/// Watch, or swipe to remove it.
final class AccountsController: UITableViewController {
    private var accounts: [SavedAccount] = []
    private let onLogIn: (SavedAccount) -> Void

    init(onLogIn: @escaping (SavedAccount) -> Void) {
        self.onLogIn = onLogIn
        super.init(style: .grouped)
        title = "Accounts"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the list over `presenter`, in its own navigation bar.
    static func present(from presenter: UIViewController, onLogIn: @escaping (SavedAccount) -> Void) {
        let navigation = UINavigationController(rootViewController: AccountsController(onLogIn: onLogIn))
        navigation.modalPresentationStyle = .formSheet
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Relay", style: .plain, target: self, action: #selector(showRelay))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))

        reload()
    }

    private func reload() {
        accounts = AccountStore.shared.all() ?? []
        tableView.reloadData()
    }

    /// Pairing with rsc-relay, which the Apple Watch plays through.
    @objc private func showRelay() {
        navigationController?.pushViewController(RelayController(), animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(accounts.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Accounts are saved here after they log in, and kept in this iPhone's keychain. "
            + "The switch sends one to the Apple Watch app, where it logs in with a tap; "
            + "accounts added on the watch stay on the watch."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        guard !accounts.isEmpty else {
            cell.textLabel?.text = "No saved accounts"
            cell.textLabel?.textColor = .gray
            cell.detailTextLabel?.text = "Log in, and the account is saved here."
            cell.selectionStyle = .none
            return cell
        }

        let account = accounts[indexPath.row]
        cell.textLabel?.text = account.username
        cell.detailTextLabel?.text = (account.worldName.isEmpty ? account.host : account.worldName)
            + (account.sharesWithWatch ? " · on Apple Watch" : "")

        let toggle = UISwitch()
        toggle.isOn = account.sharesWithWatch
        toggle.tag = indexPath.row
        toggle.accessibilityLabel = "Share \(account.username) with Apple Watch"
        toggle.addTarget(self, action: #selector(shareChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        return cell
    }

    @objc private func shareChanged(_ toggle: UISwitch) {
        guard accounts.indices.contains(toggle.tag) else { return }

        var account = accounts[toggle.tag]
        account.sharesWithWatch = toggle.isOn
        AccountStore.shared.save(account)
        PhoneWatchSync.shared.sendAccounts()
        reload()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard accounts.indices.contains(indexPath.row) else { return }

        let account = accounts[indexPath.row]

        guard !GameClient.shared.isLoggedIn else {
            let alert = UIAlertController(
                title: "Already logged in",
                message: "Log out first to switch to \(account.username).",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        dismiss(animated: true) {
            self.onLogIn(account)
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !accounts.isEmpty
    }

    override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, accounts.indices.contains(indexPath.row) else { return }

        AccountStore.shared.remove(id: accounts[indexPath.row].id)
        PhoneWatchSync.shared.sendAccounts()
        reload()
    }
}
