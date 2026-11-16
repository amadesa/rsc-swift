import CommonCrypto
import Foundation
import WatchConnectivity

/// Pairing with an rsc-relay using the code `rsc-relay pair` shows (or a
/// paired device makes):
///
///     ABCD-EFGH-JKMN-PQRS
///     └secret─┘ └─key──┘
///
/// The second half is the start of the relay's key fingerprint. It's
/// checked before the secret is sent, so a device standing in for the relay
/// never sees the secret (relay/pairing.go): during the TLS handshake on the
/// relay's own port, or, through a proxy such as Tailscale Funnel (checked
/// like any website), against the key the relay names at /v1/key. The relay
/// then gives this iPhone its own token, and one for the Apple Watch.
///
/// The addresses are tried in turn, so a home network address that can't
/// be reached (a stray VPN route, another Wi-Fi) falls back to the relay URL
/// already in use.
final class RelayPairing: NSObject, URLSessionDelegate {
    struct Paired {
        let name: String
        let baseURL: URL
        let token: String
        let watchToken: String?
        let info: RelayRoute.Info
    }

    enum Failure: LocalizedError {
        case badCode, badAddress, notThisRelay, refused(String), unreachable(String)

        var errorDescription: String? {
            switch self {
            case .badCode: return "A pairing code is 16 letters and digits, like ABCD-EFGH-JKMN-PQRS."
            case .badAddress: return "That isn't an address. Type it like 192.168.1.20 or 192.168.1.20:8443."
            case .notThisRelay: return "The relay at that address doesn't match the code. Check the address, or make a new code."
            case .refused(let message): return message
            case .unreachable(let message): return "Couldn't reach the relay: \(message)"
            }
        }
    }

    private let keyHalf: String
    private let secret: String
    private var seenPin: String?
    private var session: URLSession!

    /// nil if the code isn't a pairing code
    init?(code: String) {
        let normalized = Self.normalize(code)
        guard normalized.count == 16 else { return nil }
        secret = String(normalized.prefix(8))
        keyHalf = String(normalized.suffix(8))
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// "192.168.1.20", "192.168.1.20:8443", "[fe80::1]:8443" or a full URL.
    static func baseURL(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") {
            let hasPort = text.hasPrefix("[") ? text.contains("]:") : text.filter { $0 == ":" }.count == 1
            if !hasPort {
                text = text.contains(":") && !text.hasPrefix("[") ? "[\(text)]:8443" : text + ":8443"
            }
            text = "https://" + text
        }
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Pairs as `name` through the first of `addresses` that reaches the
    /// relay, then gets a token for the watch too if one is paired. Calls
    /// `done` on the main thread.
    func pair(addresses: [URL], name: String, _ done: @escaping (Result<Paired, Failure>) -> Void) {
        let finish: (Result<Paired, Failure>) -> Void = { result in
            DispatchQueue.main.async {
                self.session.finishTasksAndInvalidate()
                done(result)
            }
        }

        var remaining = addresses
        var firstFailure: Failure?

        func tryNext() {
            guard !remaining.isEmpty else {
                finish(.failure(firstFailure ?? .badAddress))
                return
            }
            let baseURL = remaining.removeFirst()

            pair(baseURL, name: name) { result in
                switch result {
                case .failure(let failure):
                    firstFailure = firstFailure ?? failure
                    // only a relay that couldn't be reached, or wasn't this
                    // one, is worth another address; a refused code isn't
                    switch failure {
                    case .unreachable, .notThisRelay: tryNext()
                    default: finish(.failure(failure))
                    }
                case .success:
                    finish(result)
                }
            }
        }

        tryNext()
    }

    private func pair(_ baseURL: URL, name: String, _ done: @escaping (Result<Paired, Failure>) -> Void) {
        checkKey(baseURL) { failure in
            if let failure = failure {
                done(.failure(failure))
                return
            }
            self.sendSecret(baseURL, name: name, done)
        }
    }

    /// On the relay's own port the handshake checks the key (below);
    /// through a proxy, the relay's public /v1/key is compared with the code.
    private func checkKey(_ baseURL: URL, _ done: @escaping (Failure?) -> Void) {
        guard let host = baseURL.host, !RelayRoute.isAddress(host) else {
            done(nil)
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/key"), timeoutInterval: 10)
        request.setValue(RelayCheck.clientName("iPhone"), forHTTPHeaderField: "X-RSC-Client")
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                done(.unreachable(error.localizedDescription))
                return
            }
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let pin = object?["pin"] as? String
            else {
                done(.unreachable("the relay there is older than 0.3"))
                return
            }
            guard Self.keyCode(pin) == self.keyHalf else {
                done(.notThisRelay)
                return
            }
            self.seenPin = pin
            done(nil)
        }.resume()
    }

    private func sendSecret(_ baseURL: URL, name: String, _ finish: @escaping (Result<Paired, Failure>) -> Void) {
        post(baseURL, "v1/pair", ["secret": secret, "name": name], token: nil) { result in
            switch result {
            case .failure(let failure):
                finish(.failure(failure))
            case .success(let body):
                guard let token = body["token"] as? String,
                      let data = try? JSONSerialization.data(withJSONObject: body),
                      let info = RelayRoute.Info(json: data),
                      // the relay says the key it showed in the handshake
                      info.pin == self.seenPin
                else {
                    finish(.failure(.refused("The relay's answer didn't make sense. Is it up to date?")))
                    return
                }

                let relayName = body["name"] as? String ?? baseURL.host ?? "rsc-relay"
                self.pairWatch(baseURL, token: token) { watchToken in
                    finish(.success(Paired(name: relayName, baseURL: baseURL, token: token,
                                           watchToken: watchToken, info: info)))
                }
            }
        }
    }

    /// A paired device can make a code for another; this iPhone does that
    /// for its watch.
    private func pairWatch(_ baseURL: URL, token: String, _ done: @escaping (String?) -> Void) {
        guard WCSession.isSupported(), WCSession.default.isPaired else {
            done(nil)
            return
        }

        post(baseURL, "v1/pairings", ["name": "Apple Watch"], token: token) { result in
            guard case .success(let body) = result, let code = body["code"] as? String else {
                done(nil)
                return
            }
            let secret = String(Self.normalize(code).prefix(8))
            self.post(baseURL, "v1/pair", ["secret": secret, "name": "Apple Watch"], token: nil) { result in
                guard case .success(let body) = result else {
                    done(nil)
                    return
                }
                done(body["token"] as? String)
            }
        }
    }

    private func post(
        _ baseURL: URL, _ path: String, _ body: [String: String], token: String?,
        _ done: @escaping (Result<[String: Any], Failure>) -> Void
    ) {
        // short, so an address that can't be reached falls back quickly
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RelayCheck.clientName("iPhone"), forHTTPHeaderField: "X-RSC-Client")
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { data, response, error in
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled {
                    done(.failure(.notThisRelay))
                } else {
                    done(.failure(.unreachable(error.localizedDescription)))
                }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            if (200..<300).contains(status), let object = object {
                done(.success(object))
                return
            }

            let message = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch status {
            case 403: done(.failure(.refused("Wrong pairing code. Only the newest code works: making one replaces the one before.")))
            case 410: done(.failure(.refused(message.isEmpty ? "The code expired. Make a new one." : message.prefix(1).uppercased() + message.dropFirst() + ".")))
            case 429: done(.failure(.refused("Too many wrong codes. Wait 10 minutes, then try again.")))
            case 404: done(.failure(.refused("That relay can't pair devices. Update rsc-relay.")))
            default: done(.failure(.refused("The relay answered HTTP \(status).")))
            }
        }.resume()
    }

    // MARK: - Checking the relay's key

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              RelayRoute.isAddress(challenge.protectionSpace.host)
        else {
            // a name, such as Funnel: checked like any website, and the key
            // through /v1/key
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let trust = challenge.protectionSpace.serverTrust,
              let pin = RelayRoute.pin(of: trust),
              Self.keyCode(pin) == keyHalf
        else {
            // not the relay the code is for: the secret isn't sent
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        seenPin = pin
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: - Codes

    /// Crockford's base32, as the relay writes codes.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Upper case, without dashes, with O read as 0 and I/L as 1.
    static func normalize(_ code: String) -> String {
        String(code.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return alphabet.contains(character) ? character : "?"
            }
        })
    }

    /// The key half of a code: the first 40 bits of SHA-256 of the pin
    /// text, in base32 (relay/pairing.go pinCode).
    static func keyCode(_ pin: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let bytes = Array(pin.utf8)
        _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)

        var bits: UInt64 = 0
        for byte in digest.prefix(5) {
            bits = bits << 8 | UInt64(byte)
        }
        return String((0..<8).reversed().map { alphabet[Int(bits >> (5 * UInt64($0)) & 31)] })
    }
}

/// Lists the rsc-relays on the home network (Bonjour, _rsc-relay._tcp).
final class RelayBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Found: Equatable {
        let name: String
        /// e.g. "192.168.4.52:8443"
        let address: String
    }

    /// Called on the main thread whenever the list changes.
    var onChange: (([Found]) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private(set) var found: [Found] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_rsc-relay._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services = []
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        found.removeAll { $0.name == service.name }
        onChange?(found)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard let ipv4 = service.addresses?.compactMap(Self.ipv4).first else { return }
        let entry = Found(name: service.name, address: "\(ipv4):\(service.port)")
        found.removeAll { $0.name == entry.name }
        found.append(entry)
        onChange?(found)
    }

    private static func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { buffer -> String? in
            guard buffer.count >= MemoryLayout<sockaddr_in>.size,
                  let raw = buffer.baseAddress,
                  raw.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == sa_family_t(AF_INET)
            else { return nil }

            var address = raw.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
            return String(cString: text)
        }
    }
}
