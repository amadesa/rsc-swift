import UIKit

/// Accounts > Relay: pairs RSC with an rsc-relay, which the Apple Watch
/// needs to play (and the iPhone can use too). Relays on the home network
/// are listed; tap one, type the code from `rsc-relay pair`, and Pair.
final class RelayController: UITableViewController, UITextFieldDelegate {
    private enum Section: Int, CaseIterable {
        case current, nearby, pair, invite
    }

    private let browser = RelayBrowser()
    private var nearby: [RelayBrowser.Found] = []

    /// the last code made for another device, while it's still good
    private var invitation: (code: String, expires: Date)?

    private let addressField = UITextField()
    private let codeField = UITextField()
    private var isPairing = false

    init() {
        super.init(style: .grouped)
        title = "Relay"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        for field in [addressField, codeField] {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.delegate = self
        }
        addressField.placeholder = "192.168.1.20"
        addressField.keyboardType = .URL
        addressField.returnKeyType = .next
        codeField.placeholder = "ABCD-EFGH-JKMN-PQRS"
        codeField.autocapitalizationType = .allCharacters
        codeField.returnKeyType = .go
        codeField.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .regular)

        browser.onChange = { [weak self] found in
            self?.nearby = found
            self?.tableView.reloadSections(IndexSet(integer: Section.nearby.rawValue), with: .automatic)
        }
        browser.start()
    }

    deinit {
        browser.stop()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .current: return 1
        case .nearby: return max(nearby.count, 1)
        case .pair: return 3
        case .invite: return currentRelay == nil ? 0 : (activeInvitation == nil ? 1 : 2)
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .current: return "In use"
        case .nearby: return "On this network"
        case .pair: return "Pair"
        case .invite: return currentRelay == nil ? nil : "Another device"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .pair:
            return "On the relay's computer, run  rsc-relay pair \"iPhone\"  for a code. "
                + "The code checks it's your relay before anything is sent. "
                + "The Apple Watch is paired at the same time."
        case .invite:
            return currentRelay == nil ? nil
                : "Makes a code for another iPhone, iPad or Mac to pair with this relay."
        default:
            return nil
        }
    }

    /// The relay in use, from Settings or an earlier pairing.
    private var currentRelay: (address: String, pin: String?)? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "relay_enabled"),
              let address = defaults.string(forKey: "relay_url"), !address.isEmpty
        else { return nil }
        return (address, defaults.string(forKey: "relay_pin"))
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        switch Section(rawValue: indexPath.section)! {
        case .current:
            if let relay = currentRelay {
                cell.textLabel?.text = URL(string: relay.address)?.host ?? relay.address
                cell.detailTextLabel?.text = relay.pin.map { "Key " + String($0.dropFirst(7).prefix(12)) + "…" }
                    ?? "Key not known yet (the relay is older, or hasn't been reached)"
            } else {
                cell.textLabel?.text = "No relay"
                cell.textLabel?.textColor = .gray
            }
            cell.selectionStyle = .none

        case .nearby:
            if nearby.isEmpty {
                cell.textLabel?.text = "Looking…"
                cell.textLabel?.textColor = .gray
                cell.detailTextLabel?.text = "Relays on this Wi-Fi appear here"
                cell.selectionStyle = .none
            } else {
                let relay = nearby[indexPath.row]
                cell.textLabel?.text = relay.name
                cell.detailTextLabel?.text = relay.address
                cell.accessoryType = addressField.text == relay.address ? .checkmark : .none
            }

        case .pair:
            switch indexPath.row {
            case 0: return fieldCell(addressField, label: "Address")
            case 1: return fieldCell(codeField, label: "Code")
            default:
                cell.textLabel?.text = isPairing ? "Pairing…" : "Pair"
                cell.textLabel?.textColor = isPairing ? .gray : view.tintColor
                cell.selectionStyle = isPairing ? .none : .default
            }

        case .invite:
            if indexPath.row == 1, let invitation = activeInvitation {
                cell.textLabel?.text = invitation.code
                cell.textLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
                cell.detailTextLabel?.text = "Good until \(Self.time.string(from: invitation.expires)) · tap to copy"
            } else {
                cell.textLabel?.text = activeInvitation == nil ? "Make a pairing code" : "Make a new code"
                cell.textLabel?.textColor = view.tintColor
            }
        }

        return cell
    }

    private func fieldCell(_ field: UITextField, label: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = label

        field.translatesAutoresizingMaskIntoConstraints = false
        field.textAlignment = .right
        field.removeFromSuperview()
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 100),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section)! {
        case .nearby where !nearby.isEmpty:
            addressField.text = nearby[indexPath.row].address
            tableView.reloadSections(IndexSet(integer: Section.nearby.rawValue), with: .none)
            codeField.becomeFirstResponder()
        case .pair where indexPath.row == 2:
            pair()
        case .invite where indexPath.row == 1:
            if let invitation = activeInvitation {
                copy(invitation.code)
            }
        case .invite:
            invite()
        default:
            break
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == addressField {
            codeField.becomeFirstResponder()
        } else {
            pair()
        }
        return true
    }

    // MARK: - Pairing

    private func pair() {
        guard !isPairing else { return }
        view.endEditing(true)

        guard let pairing = RelayPairing(code: codeField.text ?? "") else {
            show(RelayPairing.Failure.badCode)
            return
        }
        let typed = addressField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let addresses = pairingAddresses(typed: typed) else {
            show(RelayPairing.Failure.badAddress)
            return
        }

        setPairing(true)
        pairing.pair(addresses: addresses, name: UIDevice.current.name) { [weak self] result in
            guard let self = self else { return }
            self.setPairing(false)

            switch result {
            case .failure(let failure):
                self.show(failure)
            case .success(let paired):
                self.use(paired)
            }
        }
    }

    /// The typed address first, then the relay already in use and its other
    /// addresses, in case the typed one can't be reached from here. The code
    /// says which relay it's for, so a different relay is never paired.
    private func pairingAddresses(typed: String) -> [URL]? {
        var list: [URL] = []
        if !typed.isEmpty {
            guard let url = RelayPairing.baseURL(from: typed) else { return nil }
            list.append(url)
        }

        let defaults = UserDefaults.standard
        if let current = defaults.string(forKey: "relay_url").flatMap(URL.init(string:)),
           current.scheme == "https" {
            list.append(current)
        }
        list += RelayRoute.stored(in: defaults).endpoints.map { $0.url }

        var seen = Set<String>()
        list = list.filter { url in
            var key = url.absoluteString.lowercased()
            if key.hasSuffix("/") { key.removeLast() }
            return seen.insert(key).inserted
        }
        return list.isEmpty ? nil : list
    }

    private func use(_ paired: RelayPairing.Paired) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "relay_enabled")
        defaults.set(paired.baseURL.absoluteString, forKey: "relay_url")
        defaults.set(paired.token, forKey: "relay_token")
        defaults.set(paired.watchToken, forKey: "relay_watch_token")
        RelayRoute.store(paired.info, in: defaults)

        GameClient.shared.reloadRelay()
        PhoneWatchSync.shared.push()

        codeField.text = ""
        tableView.reloadData()

        let alert = UIAlertController(
            title: "Paired with \(paired.name)",
            message: paired.watchToken == nil
                ? "RSC uses this relay from now on."
                : "RSC and the Apple Watch use this relay from now on. Open RSC on the watch to pick it up.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func invite() {
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "relay_url"), let base = URL(string: address),
              let token = defaults.string(forKey: "relay_token")
        else { return }

        let stored = RelayRoute.stored(in: defaults)
        let route = RelayRoute(primary: base, pin: stored.pin, endpoints: stored.endpoints, isWatch: false)

        route.choose { base in
            var request = URLRequest(url: base.appendingPathComponent("v1/pairings"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(RelayCheck.clientName("iPhone"), forHTTPHeaderField: "X-RSC-Client")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": "device"])

            route.session.dataTask(with: request) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode == 201
                    ? (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["code"] as? String
                    : nil

                DispatchQueue.main.async {
                    if let code = code {
                        // the relay's codes last 10 minutes (relay/pairing.go)
                        self.invitation = (code, Date().addingTimeInterval(10 * 60))
                        self.tableView.reloadSections(IndexSet(integer: Section.invite.rawValue), with: .automatic)
                    }

                    let alert = UIAlertController(
                        title: code ?? "Couldn't make a code",
                        message: code == nil
                            ? "The relay couldn't be reached, or is older than 0.3."
                            : "Type this on the other device, in RSC's Relay screen, within 10 minutes. It works once, and a newer code replaces it.",
                        preferredStyle: .alert)
                    if let code = code {
                        alert.addAction(UIAlertAction(title: "Copy Code", style: .default) { _ in
                            self.copy(code)
                        })
                    }
                    alert.addAction(UIAlertAction(title: code == nil ? "OK" : "Done", style: .cancel))
                    self.present(alert, animated: true)
                }
            }.resume()
        }
    }

    /// The last code, until it expires.
    private var activeInvitation: (code: String, expires: Date)? {
        guard let invitation = invitation, invitation.expires > Date() else { return nil }
        return invitation
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private func copy(_ code: String) {
        UIPasteboard.general.string = code

        let alert = UIAlertController(title: "Copied", message: nil, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            alert.dismiss(animated: true)
        }
    }

    private func setPairing(_ pairing: Bool) {
        isPairing = pairing
        tableView.reloadRows(at: [IndexPath(row: 2, section: Section.pair.rawValue)], with: .none)
    }

    private func show(_ failure: RelayPairing.Failure) {
        let alert = UIAlertController(title: "Couldn't pair", message: failure.errorDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
