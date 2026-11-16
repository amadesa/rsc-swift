import Foundation

/// Works out why the game can't get through rsc-relay, one link at a time:
/// this device's internet, reaching the relay through Tailscale Funnel, the
/// relay running, the access token, the world being allowed and the relay
/// reaching the game server. Each failure says what to fix.
///
/// The relay marks its replies with an X-RSC-Relay header, which tells an
/// answer from the relay apart from Tailscale Funnel answering for a relay
/// that isn't running.
enum RelayCheck {
    /// One link in the chain, in order.
    enum Link: Int, CaseIterable {
        case internet, relayAddress, relayRunning, token, worldAllowed, gameServer

        var name: String {
            switch self {
            case .internet: return "Internet"
            case .relayAddress: return "Reach the relay"
            case .relayRunning: return "rsc-relay running"
            case .token: return "Access token"
            case .worldAllowed: return "World allowed"
            case .gameServer: return "Game server"
            }
        }
    }

    /// What went wrong, in two short lines that fit the login screen.
    struct Failure {
        let link: Link
        let title: String
        let advice: String
    }

    enum Outcome {
        case passed(String?)
        case failed(Failure)
        case notChecked
    }

    struct Step {
        let link: Link
        let outcome: Outcome
    }

    /// The steps as text, one line per link: ✓ passed, ✗ failed (with what
    /// to do), – not checked because an earlier link failed.
    static func report(_ steps: [Step]) -> String {
        steps.map { step -> String in
            switch step.outcome {
            case .passed(let detail):
                return "✓ \(step.link.name)" + (detail.map { " (\($0))" } ?? "")
            case .failed(let failure):
                return "✗ \(step.link.name): \(failure.title). \(failure.advice)"
            case .notChecked:
                return "– \(step.link.name)"
            }
        }.joined(separator: "\n")
    }

    /// What the app calls itself in X-RSC-Client, for the relay's log.
    static func clientName(_ device: String) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        return "\(device) \(version)"
    }

    // MARK: - Explaining a failed request

    /// Why a request to the relay failed, or nil if it didn't.
    static func failure(
        error: Error?, response: URLResponse?, body: Data?, isWatch: Bool
    ) -> Failure? {
        if let error = error as? URLError {
            return failure(error, isWatch: isWatch)
        } else if let error = error {
            return Failure(link: .relayAddress, title: "Can't reach the relay",
                           advice: error.localizedDescription)
        }

        guard let response = response as? HTTPURLResponse else {
            return Failure(link: .relayAddress, title: "Can't reach the relay",
                           advice: "No reply. Is the relay URL right?")
        }

        let status = response.statusCode
        guard status >= 400 else { return nil }

        let message = body.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Funnel answers for a relay that isn't running
        // (value(forHTTPHeaderField:) needs iOS 13)
        let isFromRelay = response.allHeaderFields.keys.contains {
            ($0 as? String)?.lowercased() == "x-rsc-relay"
        }

        if !isFromRelay && (502...504).contains(status) {
            return Failure(link: .relayRunning, title: "rsc-relay isn't running",
                           advice: "Start it on the relay machine")
        }

        switch status {
        case 401:
            return Failure(link: .token, title: "The relay refused the token",
                           advice: "Pair again: Accounts > Relay on iPhone")
        case 404 where !isFromRelay:
            return Failure(link: .relayRunning, title: "Relay too old, or wrong URL",
                           advice: "Update rsc-relay; check the URL")
        case 403:
            return Failure(link: .worldAllowed, title: "The relay doesn't allow this world",
                           advice: "Add it to rsc-relay's -allow list")
        case 502:
            return Failure(link: .gameServer, title: "Relay can't reach the server",
                           advice: "The game server may be down")
        case 503:
            return Failure(link: .relayRunning, title: "The relay is full",
                           advice: "Too many sessions open, try again")
        default:
            return Failure(link: .relayRunning, title: "Relay error \(status)",
                           advice: String(message.prefix(40)))
        }
    }

    private static func failure(_ error: URLError, isWatch: Bool) -> Failure {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return Failure(
                link: .internet, title: "No internet connection",
                advice: isWatch ? "Check the watch's Wi-Fi or iPhone" : "Check Wi-Fi or mobile data")
        case .cannotFindHost, .dnsLookupFailed:
            return Failure(link: .relayAddress, title: "Relay address not found",
                           advice: "Check the URL, and Tailscale Funnel")
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            if isWatch, let host = error.failingURL?.host, resolvesToTailnet(host) {
                return Failure(link: .relayAddress, title: "iPhone's Tailscale DNS is on",
                               advice: "Turn off Use Tailscale DNS in its Tailscale app")
            }
            return Failure(link: .relayAddress, title: "Can't reach the relay",
                           advice: "Is its machine on, with Funnel on?")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return Failure(link: .relayAddress, title: "Secure connection failed",
                           advice: "Is Tailscale Funnel turned on?")
        case .badURL, .unsupportedURL:
            return Failure(link: .relayAddress, title: "The relay URL is wrong",
                           advice: "It should start with https://")
        default:
            return Failure(link: .relayAddress, title: "Can't reach the relay",
                           advice: String(error.localizedDescription.prefix(40)))
        }
    }

    /// Whether `host` resolves to a Tailscale address. Online through the
    /// iPhone, the watch can be given the address from the iPhone's
    /// Tailscale DNS, which only devices on the tailnet can reach; the watch
    /// isn't on it. Blocks while resolving, so not on the main thread.
    private static func resolvesToTailnet(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return false }
        defer { freeaddrinfo(result) }

        var next = result
        while let info = next {
            if let address = info.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    // 100.64.0.0/10
                    let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                    }
                    if ip & 0xffc0_0000 == 0x6440_0000 { return true }
                case AF_INET6:
                    // fd7a:115c:a1e0::/48
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0.prefix(6)) }
                    }
                    if bytes == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return true }
                default:
                    break
                }
            }
            next = info.pointee.ai_next
        }

        return false
    }

    // MARK: - The full check

    /// Checks every link for connecting to host:port and calls `done` on the
    /// main thread with a step for each. With a route, the check goes the way
    /// the game's requests do (pinned key, or through the iPhone).
    static func run(
        baseURL: URL, token: String, client: String, host: String, port: Int,
        isWatch: Bool, route: RelayRoute? = nil, done: @escaping ([Step]) -> Void
    ) {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/check"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: "\(port)"),
        ]

        guard let url = components?.url else {
            let failure = Failure(link: .relayAddress, title: "The relay URL is wrong",
                                  advice: "It should start with https://")
            done(steps(failingAt: failure))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(client, forHTTPHeaderField: "X-RSC-Client")

        let perform: RelayRoute.Forwarder = route?.perform ?? { request, done in
            URLSession(configuration: .ephemeral).dataTask(with: request, completionHandler: done).resume()
        }

        perform(request) { data, response, error in
            let result: [Step]

            if let failure = failure(error: error, response: response, body: data, isWatch: isWatch) {
                result = steps(failingAt: failure)
            } else {
                result = steps(fromCheck: data, address: "\(host):\(port)")
            }

            DispatchQueue.main.async { done(result) }
        }
    }

    /// Every link before the failing one passed, the ones after weren't
    /// checked.
    private static func steps(failingAt failure: Failure) -> [Step] {
        Link.allCases.map { link in
            if link.rawValue < failure.link.rawValue {
                return Step(link: link, outcome: .passed(nil))
            } else if link == failure.link {
                return Step(link: link, outcome: .failed(failure))
            }
            return Step(link: link, outcome: .notChecked)
        }
    }

    /// The relay's answer to /v1/check, which shows the app got through to it.
    private static func steps(fromCheck data: Data?, address: String) -> [Step] {
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let server = (body?["servers"] as? [[String: Any]])?.first

        let isAllowed = server?["allowed"] as? Bool ?? false
        let isReachable = server?["reachable"] as? Bool ?? false
        let version = body?["version"] as? String

        var steps: [Step] = [
            Step(link: .internet, outcome: .passed(nil)),
            Step(link: .relayAddress, outcome: .passed(nil)),
            Step(link: .relayRunning, outcome: .passed(version.map { "version \($0)" })),
            Step(link: .token, outcome: .passed(nil)),
        ]

        guard isAllowed else {
            steps.append(Step(link: .worldAllowed, outcome: .failed(Failure(
                link: .worldAllowed, title: "\(address) isn't allowed",
                advice: "Add it to rsc-relay's -allow list"))))
            steps.append(Step(link: .gameServer, outcome: .notChecked))
            return steps
        }

        steps.append(Step(link: .worldAllowed, outcome: .passed(address)))

        if isReachable {
            let ms = (server?["ms"] as? NSNumber)?.intValue
            steps.append(Step(link: .gameServer, outcome: .passed(ms.map { "answered in \($0) ms" })))
        } else {
            let reason = server?["error"] as? String ?? "no answer"
            steps.append(Step(link: .gameServer, outcome: .failed(Failure(
                link: .gameServer, title: "Relay can't reach the server",
                advice: "\(reason). It may be down"))))
        }

        return steps
    }
}
