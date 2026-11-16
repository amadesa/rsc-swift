import CommonCrypto
import Foundation
import Security

/// Which address to reach rsc-relay at: the relay URL in Settings, or any
/// address the relay lists in /v1/info (home network, Tailscale, IPv6, its
/// public address, a Funnel URL).
///
/// An address that's an IP is the relay's own HTTPS port, with a
/// self-signed certificate: it's only trusted if the relay's key matches the
/// pin. An address that's a name (Tailscale Funnel) is checked like any
/// website. So every address is as safe as the others.
///
/// Before a game connection opens, the addresses are tried at once
/// (staggered, best first) and the first relay to answer is used. That gets
/// the watch past an iPhone whose Tailscale DNS hands it an address it can't
/// reach: at home it uses the home network address instead.
///
/// On the watch there's one more, last route: through the iPhone
/// (`forwarder`, WatchSync -> PhoneWatchSync), which sends the requests on
/// over its own connection. That's for away from home with the iPhone's
/// Tailscale DNS on, when no address works from the watch itself.
final class RelayRoute: NSObject, URLSessionDelegate {
    struct Endpoint: Equatable {
        let url: URL
        /// "lan", "tailscale", "ipv6", "advertised" (relay/endpoints.go)
        let kind: String
    }

    /// Sends a request to the relay some other way and calls back like a
    /// data task (the watch's route through the iPhone).
    typealias Forwarder = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    /// The base URL of the route through the iPhone.
    static let phoneBase = URL(string: "rsc-phone://relay/")!

    /// How long the watch's own addresses get before the iPhone is asked:
    /// it adds a hop, so it's only for when they don't answer.
    private static let phoneHeadStart: TimeInterval = 2.5

    /// The relay URL from Settings.
    let primary: URL
    /// The relay's key, "sha256/<base64>", if it's known.
    let pin: String?
    let endpoints: [Endpoint]
    private let forwarder: Forwarder?

    private let isWatch: Bool
    private let queue = DispatchQueue(label: "rsc.relay.route")
    /// only touched on `queue`
    private var current: URL?
    private var choosing: [(URL) -> Void] = []

    /// For every request to the relay, so pinned addresses are checked.
    private(set) var session: URLSession!

    /// The relay's own port is reached by IP address, a proxy by name.
    static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    init(primary: URL, pin: String?, endpoints: [Endpoint], isWatch: Bool,
         forwarder: Forwarder? = nil) {
        self.primary = primary
        self.pin = pin
        self.isWatch = isWatch
        self.forwarder = forwarder

        // pinned addresses are no use without the pin; the watch is never on
        // the tailnet
        self.endpoints = pin == nil ? [] : endpoints.filter {
            $0.url.scheme == "https" && !(isWatch && $0.kind == "tailscale")
        }

        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The address in use, or the relay URL until one has been chosen.
    var base: URL {
        queue.sync { current ?? primary }
    }

    /// Whether requests go through the iPhone, which adds a hop.
    var isThroughPhone: Bool {
        base == Self.phoneBase
    }

    /// Sends a request to the relay, directly or through the iPhone,
    /// whichever its URL says. `done` is called on a background queue.
    func perform(_ request: URLRequest, _ done: @escaping (Data?, URLResponse?, Error?) -> Void) {
        if request.url?.scheme == Self.phoneBase.scheme {
            guard let forwarder = forwarder else {
                done(nil, nil, URLError(.unsupportedURL))
                return
            }
            forwarder(request, done)
        } else {
            session.dataTask(with: request, completionHandler: done).resume()
        }
    }

    /// Picks the address to use: the first to answer a health check, trying
    /// the last one that worked first. Calls `done` on the route's queue.
    func choose(_ done: @escaping (URL) -> Void) {
        queue.async {
            self.choosing.append(done)
            guard self.choosing.count == 1 else { return } // already choosing

            let candidates = self.candidates()
            guard candidates.count > 1 || self.forwarder != nil else {
                self.finishChoosing(candidates.first ?? self.primary)
                return
            }

            self.race(candidates)
        }
    }

    /// After requests keep failing: choose again before the next one.
    func forget() {
        queue.async { self.current = nil }
    }

    /// Best first: the address that worked last, the home network, the relay
    /// URL, then the rest. Not the iPhone: it always comes last (`race`).
    private func candidates() -> [URL] {
        func rank(_ kind: String) -> Int {
            switch kind {
            case "lan": return 0
            case "tailscale": return 1
            case "primary": return 2
            case "public": return 3
            case "ipv6": return 4
            default: return 5
            }
        }

        var list = (endpoints + [Endpoint(url: primary, kind: "primary")])
            .sorted { rank($0.kind) < rank($1.kind) }
            .map { $0.url }

        if let last = current, let index = list.firstIndex(of: last) {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }

    /// Starts a health check on each candidate, 0.3 s apart, and takes the
    /// first relay that answers. The iPhone, if there's a forwarder, is
    /// asked after a head start, or as soon as every address has failed.
    /// Called on `queue`.
    private func race(_ candidates: [URL]) {
        var isDecided = false
        var remaining = candidates.count + (forwarder == nil ? 0 : 1)
        var tasks: [URLSessionDataTask] = []
        var isPhoneAsked = false
        var askPhone: () -> Void = {}

        let decide: (URL?) -> Void = { winner in
            // on `queue`
            remaining -= 1
            guard !isDecided else { return }

            if let winner = winner {
                isDecided = true
                tasks.forEach { $0.cancel() }
                self.finishChoosing(winner)
            } else if remaining == 0 {
                isDecided = true
                // none answered: use the relay URL, whose errors are explained
                self.finishChoosing(self.primary)
            } else if remaining == 1 && self.forwarder != nil && !isPhoneAsked {
                // only the iPhone is left: no need to wait out its head start
                askPhone()
            }
        }

        let healthCheck = { (base: URL) -> URLRequest in
            var request = URLRequest(url: base.appendingPathComponent("v1/health"), timeoutInterval: 5)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        }
        let answered = { (response: URLResponse?) -> Bool in
            (response as? HTTPURLResponse).map { $0.statusCode == 200 && Self.isFromRelay($0) } ?? false
        }

        for (index, base) in candidates.enumerated() {
            let task = session.dataTask(with: healthCheck(base)) { [weak self] _, response, _ in
                self?.queue.async { decide(answered(response) ? base : nil) }
            }
            tasks.append(task)

            queue.asyncAfter(deadline: .now() + 0.3 * Double(index)) {
                if !isDecided { task.resume() } else { decide(nil) }
            }
        }

        guard let forwarder = forwarder else { return }

        askPhone = { [weak self] in
            guard !isPhoneAsked, !isDecided else { return }
            isPhoneAsked = true
            forwarder(healthCheck(Self.phoneBase)) { _, response, _ in
                self?.queue.async { decide(answered(response) ? Self.phoneBase : nil) }
            }
        }
        queue.asyncAfter(deadline: .now() + Self.phoneHeadStart) { askPhone() }
    }

    /// Called on `queue`.
    private func finishChoosing(_ base: URL) {
        if base != primary || current == nil {
            print(base == Self.phoneBase ? "relay: going through the iPhone"
                                         : "relay: using \(base.absoluteString)")
        }
        current = base
        let waiting = choosing
        choosing = []
        waiting.forEach { $0(base) }
    }

    static func isFromRelay(_ response: HTTPURLResponse) -> Bool {
        response.allHeaderFields.keys.contains { ($0 as? String)?.lowercased() == "x-rsc-relay" }
    }

    // MARK: - Pinning

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace

        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              Self.isAddress(space.host)
        else {
            // a name, e.g. Funnel: checked like any website
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if let pin = pin, Self.pin(of: trust) == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            print("relay: \(space.host) isn't the paired relay (its key doesn't match)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// The pin of the server's key: SHA-256 of its SubjectPublicKeyInfo, as
    /// the relay computes it (relay/identity.go). The relay's key is P-256.
    static func pin(of trust: SecTrust) -> String? {
        let key: SecKey?
        if #available(iOS 14, watchOS 7, *) {
            key = SecTrustCopyKey(trust)
        } else {
            key = SecTrustCopyPublicKey(trust)
        }

        guard let publicKey = key,
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits as String] as? Int == 256,
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              raw.count == 65
        else { return nil }

        // DER header of a P-256 SubjectPublicKeyInfo, before the 65-byte point
        let header: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ]
        let spki = Data(header) + raw

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        spki.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return "sha256/" + Data(digest).base64EncodedString()
    }
}

// MARK: - What the relay says about itself

extension RelayRoute {
    /// /v1/info: the relay's key and the addresses it can be reached at.
    struct Info {
        let pin: String
        let endpoints: [Endpoint]

        init?(json data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pin = object["pin"] as? String, pin.hasPrefix("sha256/")
            else { return nil }

            self.pin = pin
            endpoints = (object["endpoints"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let address = entry["url"] as? String, let url = URL(string: address),
                      url.scheme == "https"
                else { return nil }
                return Endpoint(url: url, kind: entry["kind"] as? String ?? "advertised")
            }
        }
    }

    /// Asks the relay for its key and addresses, through whichever address
    /// works. Calls `done` on the main thread, with nil if it couldn't.
    func fetchInfo(token: String, client: String, _ done: @escaping (Info?) -> Void) {
        choose { base in
            var request = URLRequest(url: base.appendingPathComponent("v1/info"), timeoutInterval: 15)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(client, forHTTPHeaderField: "X-RSC-Client")

            self.perform(request) { data, response, _ in
                let info = (response as? HTTPURLResponse)?.statusCode == 200
                    ? data.flatMap(Info.init(json:)) : nil
                DispatchQueue.main.async { done(info) }
            }
        }
    }

    /// The pin and addresses as kept in UserDefaults (and sent to the watch).
    static func stored(in defaults: UserDefaults) -> (pin: String?, endpoints: [Endpoint]) {
        let pin = defaults.string(forKey: "relay_pin")
        let endpoints = (defaults.array(forKey: "relay_endpoints") as? [[String: String]] ?? [])
            .compactMap { entry -> Endpoint? in
                guard let address = entry["url"], let url = URL(string: address) else { return nil }
                return Endpoint(url: url, kind: entry["kind"] ?? "advertised")
            }
        return (pin, endpoints)
    }

    static func store(_ info: Info, in defaults: UserDefaults) {
        defaults.set(info.pin, forKey: "relay_pin")
        defaults.set(info.endpoints.map { ["url": $0.url.absoluteString, "kind": $0.kind] },
                     forKey: "relay_endpoints")
    }
}
