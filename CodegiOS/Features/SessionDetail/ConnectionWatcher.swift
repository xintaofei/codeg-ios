import Foundation

/// Keeps a subscription on the conversation's connection BETWEEN turns.
///
/// The session screen opens its turn stream only to send, or to follow a turn
/// already running, and closes it when the turn ends. But a connection keeps
/// working after that: background shells and sub-agents outlive their turn,
/// delegations run on, Claude starts turns of its own — and the predicted next
/// prompt arrives only AFTER `turn_complete`. The web stays attached for the
/// connection's whole life; this is the iOS stand-in, scoped to the screen.
///
/// It feeds ONLY ``ConnectionRunsModel``. It never builds a live turn and never
/// writes the screen's connection id — it is an observer, and yields the
/// moment a turn stream opens (the view model stops it on every stream open).
/// Nothing is lost in the hand-off: everything the runs model holds is current
/// state that every snapshot restates.
///
/// Ownership and staleness:
/// - Every socket gets a generation; a consumer whose generation is no longer
///   current ignores its frames, so an old socket's late frame can never apply
///   after a newer attach (or after `stop`).
/// - `isCurrent` is the owner's lifetime check, captured where the watch was
///   REQUESTED: a reconnect that wakes up after the screen's teardown — even
///   one followed by a reappearance — never re-opens a socket.
@MainActor
final class ConnectionWatcher {
    /// The connection being watched — or, after a stop, the last one, so a
    /// screen that comes back can pick it up again. Cleared once the server
    /// says it is gone.
    private(set) var connectionID: String?
    /// A socket is open, or a reconnect is pending.
    private(set) var isWatching = false

    /// Follow-up work the owner hangs off a watch (re-reading the transcript
    /// after an autonomous turn), cancelled with it.
    var followUpTask: Task<Void, Never>?
    /// What else the screen takes off the watched connection besides the
    /// running list — its commands, whether it can fork. Both are current
    /// state, so a frame the turn stream also delivered does no harm.
    var onSnapshot: (@MainActor (LiveSessionSnapshot) -> Void)?
    var onEvent: (@MainActor (AcpEvent) -> Void)?

    /// Everything one watch needs, fixed when it is requested.
    private struct Target {
        let connectionID: String
        let baseURL: URL
        let token: String
        let runs: ConnectionRunsModel
        /// The owner's lifetime check, captured at the request.
        let isCurrent: @MainActor () -> Bool
    }

    private let subscriptionID = UUID().uuidString
    private var stream: EventStream?
    private var consumerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0
    /// Consecutive reconnects with no attach confirmed in between.
    private var reconnects = 0
    private static let maxReconnects = 8

    /// Watch `conn`, feeding `runs`. A no-op while already watching it.
    func start(connectionID conn: String, feeding runs: ConnectionRunsModel,
               baseURL: URL, token: String, isCurrent: @escaping @MainActor () -> Bool) {
        if isWatching, connectionID == conn { return }
        closeSocket()
        guard isCurrent() else { return }
        connectionID = conn
        isWatching = true
        reconnects = 0
        open(Target(connectionID: conn, baseURL: baseURL, token: token, runs: runs, isCurrent: isCurrent),
             resume: false)
    }

    /// Stop watching: a turn stream is taking over, or the screen is gone.
    func stop() {
        closeSocket()
        isWatching = false
        followUpTask?.cancel()
        followUpTask = nil
    }

    /// Stop, and don't pick this connection up again.
    func forget() {
        stop()
        connectionID = nil
    }

    // MARK: - Socket

    private func open(_ target: Target, resume: Bool) {
        generation &+= 1
        let socketGeneration = generation
        let newStream = EventStream(baseURL: target.baseURL, token: target.token)
        stream = newStream
        newStream.start()
        consumerTask = Task { [weak self] in
            await self?.consume(stream: newStream, target: target, generation: socketGeneration, resume: resume)
        }
    }

    /// Retire the current socket (and anything waiting to replace it). Bumping
    /// the generation is what makes its consumer drop whatever it still has.
    private func closeSocket() {
        generation &+= 1
        consumerTask?.cancel()
        consumerTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stream?.detach(subscriptionId: subscriptionID)
        stream?.close()
        stream = nil
    }

    private func consume(stream: EventStream, target: Target, generation socketGeneration: Int, resume: Bool) async {
        let conn = target.connectionID
        let runs = target.runs
        for await frame in stream.frames {
            guard !Task.isCancelled, socketGeneration == generation, target.isCurrent() else { return }
            switch frame {
            case .ready:
                // A reconnect resumes from the last event applied, so a short
                // gap is replayed rather than re-sent whole. The first attach
                // asks for a snapshot: it is the authoritative current state.
                let since = resume && runs.connectionID == conn ? runs.lastSeq : nil
                stream.attach(subscriptionId: subscriptionID, connectionId: conn, sinceSeq: since)
            case .snapshot(let snap):
                reconnects = 0
                runs.hydrate(snap, connection: conn)
                onSnapshot?(snap)
            case .replay(let events):
                reconnects = 0
                for envelope in events {
                    runs.apply(envelope.event, seq: envelope.seq)
                    onEvent?(envelope.event)
                }
            case .event(let envelope):
                runs.apply(envelope.event, seq: envelope.seq)
                onEvent?(envelope.event)
            case .pong:
                break
            case .detached(let reason):
                if reason == "connection_gone" {
                    // Terminal: whatever it listed died with it.
                    runs.connectionGone(conn)
                    closeSocket()
                    isWatching = false
                    connectionID = nil
                } else {
                    // `lagged` / `server_shutdown`: transient, re-attach.
                    scheduleReconnect(target)
                }
                return
            case .closed:
                // The connection outlives the socket: a dropped socket is a blip.
                scheduleReconnect(target)
                return
            }
        }
    }

    /// Re-attach after a drop, backing off; gives up quietly after
    /// `maxReconnects` attempts in a row that never got an attach confirmed.
    /// The next turn's end, or the screen reappearing, starts a fresh watch.
    private func scheduleReconnect(_ target: Target) {
        closeSocket()
        reconnects += 1
        guard reconnects <= Self.maxReconnects, target.isCurrent() else {
            isWatching = false
            return
        }
        let attempt = reconnects
        let pendingGeneration = generation
        reconnectTask = Task { [weak self] in
            // 0.5, 1, 2, 4, 8, 15, 15 … seconds.
            let delay = min(15.0, 0.5 * pow(2.0, Double(attempt - 1)))
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, pendingGeneration == self.generation,
                  self.isWatching, self.connectionID == target.connectionID, target.isCurrent() else { return }
            self.open(target, resume: true)
        }
    }
}
