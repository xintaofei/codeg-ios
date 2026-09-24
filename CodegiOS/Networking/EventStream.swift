import Foundation

// MARK: - WebSocket attach-protocol messages

/// Client→server attach-protocol message (Rust `ClientMsg`, tagged `action`).
/// Encode-only; snake_case wire keys are spelled explicitly (request encoder
/// does not convert keys).
enum WSClientMessage: Encodable, Sendable {
    case attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?)
    case detach(subscriptionId: String)
    case ping

    private enum CodingKeys: String, CodingKey {
        case action
        case subscriptionId = "subscription_id"
        case connectionId = "connection_id"
        case sinceSeq = "since_seq"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attach(let sub, let conn, let since):
            try c.encode("attach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
            try c.encode(conn, forKey: .connectionId)
            try c.encodeIfPresent(since, forKey: .sinceSeq)
        case .detach(let sub):
            try c.encode("detach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
        case .ping:
            try c.encode("ping", forKey: .action)
        }
    }
}

/// Server→client attach-protocol message (Rust `ServerMsg`, tagged `type`).
/// Decoded with the shared `.convertFromSnakeCase` decoder, so keys are
/// camelCase here.
enum WSServerMessage: Decodable, Sendable {
    case snapshot(LiveSessionSnapshot)
    case replay([EventEnvelope])
    case event(EventEnvelope)
    case detached(reason: String)
    case pong
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, snapshot, events, envelope, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot":
            self = .snapshot(try c.decode(LiveSessionSnapshot.self, forKey: .snapshot))
        case "replay":
            self = .replay(try c.decodeIfPresent([EventEnvelope].self, forKey: .events) ?? [])
        case "event":
            self = .event(try c.decode(EventEnvelope.self, forKey: .envelope))
        case "detached":
            self = .detached(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "pong":
            self = .pong
        default:
            self = .unknown
        }
    }
}

// MARK: - EventStream

/// A live WebSocket connection to `/ws/events`. Emits decoded frames on
/// `frames`. Lifecycle: `start()` → await `.ready` → `attach(...)` → consume
/// `.event` frames → `close()`. Reconnection is the caller's responsibility
/// (Phase 1 reconnects by creating a fresh stream).
final class EventStream: @unchecked Sendable {
    enum Frame: Sendable {
        case ready
        case snapshot(LiveSessionSnapshot)
        case replay([EventEnvelope])
        case event(EventEnvelope)
        case detached(reason: String)
        case pong
        case closed(reason: String?)
    }

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let url: URL
    private let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var isClosed = false

    /// Dedicated session for the long-lived event socket. `URLSession.shared`'s
    /// default `timeoutIntervalForRequest` (60s) is an *inactivity* timeout that,
    /// on a WebSocket, fires whenever the agent goes quiet — a long tool call, a
    /// pause for a permission prompt — and tears down a perfectly healthy stream,
    /// surfacing a spurious error even though the server is fine. A live agent
    /// owns the pacing, so the socket must be allowed to sit idle indefinitely;
    /// genuine death is instead detected by the keepalive ping below. (The
    /// browser WebSocket the web client uses has no such idle timeout — this
    /// brings parity.)
    static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 604_800   // 7 days — effectively no idle timeout
        cfg.timeoutIntervalForResource = 604_800
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Seconds between keepalive pings. With the idle timeout disabled, these are
    /// how a genuinely dead connection is detected: the pong handler errors when
    /// the socket is gone, and we surface that as a `.closed` frame.
    private static let pingInterval: TimeInterval = 20

    init(baseURL: URL, token: String, session: URLSession = EventStream.streamSession) {
        self.token = token
        self.session = session
        self.url = EventStream.websocketURL(from: baseURL)
        var captured: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    func start() {
        let protocols = ["codeg-events", "codeg-token.\(EventStream.base64URLNoPad(token))"]
        let newTask = session.webSocketTask(with: url, protocols: protocols)
        lock.lock(); task = newTask; lock.unlock()
        newTask.resume()
        receiveLoop()
        // Begin the keepalive after one interval so the handshake completes first
        // (a ping fired before the socket connects would error and falsely close).
        scheduleNextPing()
    }

    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64? = nil) {
        send(.attach(subscriptionId: subscriptionId, connectionId: connectionId, sinceSeq: sinceSeq))
    }

    func detach(subscriptionId: String) { send(.detach(subscriptionId: subscriptionId)) }

    func ping() { send(.ping) }

    func close() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        let t = task
        lock.unlock()
        guard !alreadyClosed else { return }
        t?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    // MARK: - Private

    private func send(_ message: WSClientMessage) {
        guard let data = try? CodegJSON.encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); let t = task; lock.unlock()
        t?.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        lock.lock(); let t = task; lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(reason: error.localizedDescription)
            case .success(let message):
                self.handle(message)
                self.lock.lock(); let closed = self.isClosed; self.lock.unlock()
                if !closed { self.receiveLoop() }
            }
        }
    }

    private func finish(reason: String?) {
        lock.lock()
        let already = isClosed
        isClosed = true
        lock.unlock()
        guard !already else { return }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }

    // MARK: - Keepalive

    /// Schedule the next keepalive ping after `pingInterval`, unless closed.
    private func scheduleNextPing() {
        lock.lock(); let closed = isClosed; lock.unlock()
        guard !closed else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + EventStream.pingInterval) { [weak self] in
            self?.sendKeepalivePing()
        }
    }

    /// Send a WebSocket ping and reschedule on success. On failure the socket is
    /// genuinely gone, so finish the stream. A quiet-but-healthy turn never trips
    /// this — the server (axum) always returns the pong, resetting the cycle.
    private func sendKeepalivePing() {
        lock.lock(); let closed = isClosed; let t = task; lock.unlock()
        guard !closed, let t else { return }
        t.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(reason: error.localizedDescription)
            } else {
                self.scheduleNextPing()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        decode(data)
    }

    private func decode(_ data: Data) {
        // The socket multiplexes the legacy firehose ({channel, payload}) with
        // the attach protocol ({type, ...}). Route on which key is present.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let channel = obj["channel"] as? String {
                if channel == "__ready__" { continuation.yield(.ready) }
                return // ignore other legacy global events in Phase 1
            }
            guard obj["type"] is String else { return }
        }
        guard let message = try? CodegJSON.decoder.decode(WSServerMessage.self, from: data) else { return }
        switch message {
        case .snapshot(let snapshot): continuation.yield(.snapshot(snapshot))
        case .replay(let events): continuation.yield(.replay(events))
        case .event(let envelope): continuation.yield(.event(envelope))
        case .detached(let reason): continuation.yield(.detached(reason: reason))
        case .pong: continuation.yield(.pong)
        case .unknown: break
        }
    }

    // MARK: - Helpers

    static func base64URLNoPad(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func websocketURL(from baseURL: URL) -> URL {
        // Append the endpoint to the configured server URL so deployments under
        // a reverse-proxy path (e.g. https://host/codeg) keep their base path.
        let endpointURL = baseURL
            .appendingPathComponent("ws")
            .appendingPathComponent("events")
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        components?.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        components?.query = nil
        return components?.url ?? endpointURL
    }
}
