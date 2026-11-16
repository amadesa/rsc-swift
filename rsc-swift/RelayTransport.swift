import Foundation

/// Carries the game's connection over HTTPS through rsc-relay (relay/), for
/// watchOS where raw TCP isn't allowed. The C side (relay-transport.c)
/// treats it like a socket: this class opens a relay session, long-polls
/// for bytes from the server, and posts the bytes the game writes.
///
/// Every request carries a stream offset, so on a flaky connection any
/// request can be retried without bytes being lost or sent twice. Every
/// address the relay is reachable at leads to the same relay, so a session
/// carries on if RelayRoute switches address part way, including to the
/// route through the iPhone.
final class RelayTransport {
    struct Settings {
        let baseURL: URL
        let token: String
        /// "watch", "iPhone" etc., named in the relay's log
        var device = "iPhone"
        var isWatch = false
        /// the relay's key and its other addresses, from /v1/info
        var pin: String?
        var endpoints: [RelayRoute.Endpoint] = []
        /// the watch's last route, through the iPhone (WatchSync.forward)
        var forwarder: RelayRoute.Forwarder?
    }

    /// Called on the main thread when a connection couldn't be opened, with
    /// the host and port it was for (to run RelayCheck).
    var onOpenFailed: ((String, Int, RelayCheck.Failure) -> Void)?

    private let settings: Settings
    private let queue = DispatchQueue(label: "rsc.relay")
    /// which of the relay's addresses requests go to
    let route: RelayRoute

    // all below only touched on `queue`
    private var generation: Int32 = 0
    private var sessionID: String?
    private var isClosed = true
    private var receivedOffset: Int64 = 0
    private var sentOffset: Int64 = 0
    /// taken from the game, not yet confirmed by the relay
    private var outgoing = Data()
    private var isSending = false

    private static let pollWait = 20_000 // ms the relay holds a recv
    private static let maxChunk = 64 << 10 // the relay's request size limit
    // through the iPhone, each request is a WatchConnectivity message, which
    // has to be answered quickly and kept small
    private static let phonePollWait = 4_000
    private static let phoneMaxChunk = 16 << 10
    private static let maxFailures = 8 // about 20 s of retrying

    private let clientName: String

    init(settings: Settings) {
        self.settings = settings
        clientName = RelayCheck.clientName(settings.device)

        route = RelayRoute(primary: settings.baseURL, pin: settings.pin,
                           endpoints: settings.endpoints, isWatch: settings.isWatch,
                           forwarder: settings.forwarder)
    }

    /// Routes new game connections through the relay.
    func install() {
        var callbacks = RelayCallbacks()
        callbacks.context = Unmanaged.passRetained(self).toOpaque()

        callbacks.open = { context, generation, host, port in
            let transport = Unmanaged<RelayTransport>.fromOpaque(context!).takeUnretainedValue()
            let hostName = host.map { String(cString: $0) } ?? ""
            transport.queue.async {
                transport.open(generation: generation, host: hostName, port: Int(port))
            }
        }

        callbacks.send = { context, generation in
            let transport = Unmanaged<RelayTransport>.fromOpaque(context!).takeUnretainedValue()
            transport.queue.async { transport.pumpSends(generation: generation) }
        }

        callbacks.close = { context, generation in
            let transport = Unmanaged<RelayTransport>.fromOpaque(context!).takeUnretainedValue()
            transport.queue.async { transport.close(generation: generation) }
        }

        rsc_relay_configure(1, callbacks)
    }

    // MARK: - Session

    private func open(generation: Int32, host: String, port: Int) {
        endSession()

        self.generation = generation
        isClosed = false
        receivedOffset = 0
        sentOffset = 0
        outgoing = Data()
        isSending = false

        // the address that answers first, then the session
        route.choose { [weak self] _ in
            self?.queue.async { self?.createSession(generation: generation, host: host, port: port) }
        }
    }

    private func createSession(generation: Int32, host: String, port: Int) {
        guard generation == self.generation, !isClosed else { return }

        var request = makeRequest(path: "v1/sessions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // answer before the game gives up waiting (relay-transport.c)
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["host": host, "port": port])

        route.perform(request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                guard generation == self.generation, !self.isClosed else { return }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                let id = (body as? [String: Any])?["id"] as? String

                guard status == 201, let sessionID = id else {
                    let failure = RelayCheck.failure(
                        error: error, response: response, body: data,
                        isWatch: self.settings.isWatch)
                        ?? RelayCheck.Failure(link: .relayRunning, title: "The relay gave no session",
                                              advice: "Check the relay is up to date")

                    print("relay: couldn't open a session to \(host):\(port): "
                          + "\(failure.title). \(failure.advice) (HTTP \(status), \(error.map { "\($0)" } ?? "no error"))")

                    self.isClosed = true
                    rsc_relay_failed(generation, failure.title, failure.advice)
                    rsc_relay_opened(generation, 0)

                    DispatchQueue.main.async { self.onOpenFailed?(host, port, failure) }
                    return
                }

                self.sessionID = sessionID
                rsc_relay_opened(generation, 1)
                self.poll(generation: generation, failures: 0)
            }
        }
    }

    private func close(generation: Int32) {
        guard generation == self.generation else { return }
        endSession()
    }

    /// Stops this session, telling the game (if it doesn't already know) and
    /// the relay (best effort, it also closes idle sessions itself).
    private func finish(generation: Int32) {
        guard generation == self.generation, !isClosed else { return }
        endSession()
        rsc_relay_closed(generation)
    }

    private func endSession() {
        isClosed = true

        if let sessionID = sessionID {
            route.perform(makeRequest(path: "v1/sessions/\(sessionID)", method: "DELETE")) { _, _, _ in }
        }

        sessionID = nil
    }

    // MARK: - Receiving

    private func poll(generation: Int32, failures: Int) {
        guard generation == self.generation, !isClosed, let sessionID = sessionID else { return }

        let wait = route.isThroughPhone ? Self.phonePollWait : Self.pollWait
        let request = makeRequest(
            path: "v1/sessions/\(sessionID)/recv",
            query: "from=\(receivedOffset)&wait=\(wait)")

        route.perform(request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                guard generation == self.generation, !self.isClosed else { return }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if status == 200 {
                    let bytes = data ?? Data()
                    if !bytes.isEmpty {
                        bytes.withUnsafeBytes { buffer in
                            rsc_relay_received(generation, buffer.baseAddress, buffer.count)
                        }
                        self.receivedOffset += Int64(bytes.count)
                    }
                    self.poll(generation: generation, failures: 0)
                } else if error != nil || status >= 500 {
                    // the network dropped out; ask for the same offset again
                    self.retry(failures: failures, generation: generation) {
                        self.poll(generation: generation, failures: failures + 1)
                    }
                } else {
                    // 404 expired, 409 lost sync, 410 server hung up, 401 token
                    self.finish(generation: generation)
                }
            }
        }
    }

    // MARK: - Sending

    private func pumpSends(generation: Int32) {
        guard generation == self.generation, !isClosed, !isSending,
              let sessionID = sessionID
        else { return }

        // collect everything the game has queued
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let taken = rsc_relay_take_pending(generation, &chunk, chunk.count)
            if taken == 0 { break }
            outgoing.append(chunk, count: taken)
        }

        guard !outgoing.isEmpty else { return }

        let body = outgoing.prefix(route.isThroughPhone ? Self.phoneMaxChunk : Self.maxChunk)
        let at = sentOffset
        isSending = true

        send(Data(body), at: at, sessionID: sessionID, generation: generation, failures: 0)
    }

    private func send(_ body: Data, at: Int64, sessionID: String, generation: Int32, failures: Int) {
        var request = makeRequest(
            path: "v1/sessions/\(sessionID)/send", query: "at=\(at)", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        route.perform(request) { [weak self] _, response, error in
            guard let self = self else { return }
            self.queue.async {
                guard generation == self.generation, !self.isClosed else { return }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if status == 204 {
                    self.outgoing.removeFirst(body.count)
                    self.sentOffset += Int64(body.count)
                    self.isSending = false
                    self.pumpSends(generation: generation)
                } else if error != nil || status >= 500 {
                    // resend from the same offset; the relay skips what it has
                    self.retry(failures: failures, generation: generation) {
                        self.send(body, at: at, sessionID: sessionID,
                                  generation: generation, failures: failures + 1)
                    }
                } else {
                    self.finish(generation: generation)
                }
            }
        }
    }

    // MARK: - Helpers

    private func retry(failures: Int, generation: Int32, _ action: @escaping () -> Void) {
        guard failures < Self.maxFailures else {
            finish(generation: generation)
            return
        }

        let delay = min(0.25 * pow(2, Double(failures)), 4)

        // still failing: the network may have changed (left home, Wi-Fi to
        // the iPhone), so find the address that works now
        if failures == 2 {
            route.forget()
            route.choose { [weak self] _ in
                self?.queue.asyncAfter(deadline: .now() + delay, execute: action)
            }
            return
        }

        queue.asyncAfter(deadline: .now() + delay, execute: action)
    }

    private func makeRequest(path: String, query: String? = nil, method: String = "GET") -> URLRequest {
        var url = route.base.appendingPathComponent(path)

        if let query = query, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientName, forHTTPHeaderField: "X-RSC-Client")
        return request
    }
}
