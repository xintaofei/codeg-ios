import Foundation

/// A live-feedback ("steering") note on the running turn (Rust `FeedbackItem`).
///
/// Two channels deliver one (`SessionState.native_steering_available` picks):
/// - native `_session/steering` push: the note is inserted into the running
///   turn at once and arrives already `delivered` — the transcript shows it as
///   a user message splitting the reply;
/// - the `check_user_feedback` pull tool: the note waits, `pending`, until the
///   agent next checks, and flips to `delivered` on `feedback_consumed`.
struct FeedbackItem: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let text: String
    let createdAt: String?
    var status: String
    var deliveredAt: String?

    var isDelivered: Bool { status == "delivered" }

    init(id: String, text: String, createdAt: String? = nil, status: String, deliveredAt: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.deliveredAt = deliveredAt
    }

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, status, deliveredAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        deliveredAt = try? c.decodeIfPresent(String.self, forKey: .deliveredAt)
    }
}

/// Which channel a mid-turn message rides (see ``FeedbackItem``).
enum SteerChannel: Equatable, Sendable { case native, pull }

/// The current turn's live-feedback notes — port of the state the web's
/// `useSessionFeedback` keeps (codeg 0.44).
///
/// - Notes merge by id; a live event wins over the snapshot's copy.
/// - A `feedback_consumed` that races ahead of the note it consumes is kept as
///   a tombstone and applied when the note shows up.
/// - The next turn's `user_message` clears everything: notes are turn-scoped.
struct FeedbackNotes: Equatable {
    private(set) var notes: [FeedbackItem] = []
    private var consumed: [String: String] = [:]
    private var dismissed: Set<String> = []

    /// Adopt the snapshot's notes (live ones already held win).
    mutating func hydrate(_ items: [FeedbackItem]) {
        var byId: [String: FeedbackItem] = [:]
        var order: [String] = []
        for item in items where !dismissed.contains(item.id) && !item.id.isEmpty {
            var n = item
            if let at = consumed[n.id] { n.status = "delivered"; n.deliveredAt = at }
            if byId[n.id] == nil { order.append(n.id) }
            byId[n.id] = n
        }
        for n in notes {
            if byId[n.id] == nil { order.append(n.id) }
            // The live copy wins — except that being read is one-way: a
            // snapshot taken after a consume this client missed (a socket gap
            // too long to replay) knows better than the `pending` copy held.
            if let snap = byId[n.id], snap.isDelivered, !n.isDelivered {
                byId[n.id] = snap
            } else {
                byId[n.id] = n
            }
        }
        notes = order.compactMap { byId[$0] }
    }

    /// A note was recorded (the broadcast, or this client's own submit reply).
    mutating func submitted(_ item: FeedbackItem) {
        guard !item.id.isEmpty, !dismissed.contains(item.id), !notes.contains(where: { $0.id == item.id }) else { return }
        var n = item
        if let at = consumed[n.id] { n.status = "delivered"; n.deliveredAt = at }
        notes.append(n)
    }

    /// The agent read these notes.
    mutating func consumed(ids: [String], at: String?) {
        let stamp = at ?? ""
        for id in ids { consumed[id] = stamp }
        let set = Set(ids)
        notes = notes.map { n in
            guard set.contains(n.id) else { return n }
            var out = n
            out.status = "delivered"
            out.deliveredAt = at
            return out
        }
    }

    /// The next turn began.
    mutating func newTurn() {
        notes = []
        consumed = [:]
        dismissed = []
    }

    /// Retire a row (resent as a message, or dismissed).
    mutating func dismiss(_ id: String) {
        dismissed.insert(id)
        notes.removeAll { $0.id == id }
    }

    /// The rows to draw above the composer. Notes the transcript adopted as
    /// mid-turn messages are left out (they would show twice). Once the turn is
    /// over only the unread ones stay — in their expired form.
    func visible(turnRunning: Bool, adopted: Set<String>) -> [FeedbackItem] {
        let unadopted = notes.filter { !adopted.contains($0.id) }
        return turnRunning ? unadopted : unadopted.filter { !$0.isDelivered }
    }
}

/// A message written while a turn was running, waiting to be sent as the next
/// one (web `useMessageQueue`).
struct QueuedPrompt: Identifiable, Hashable, Sendable {
    let id: UUID
    var text: String
    var attachments: [Attachment]

    init(id: UUID = UUID(), text: String, attachments: [Attachment] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}

/// The messages waiting to go out, oldest first (web `useMessageQueue`).
///
/// FIFO is the whole contract: a message the user sends while others wait
/// joins the END of the line, and one that went out and bounced off a turn
/// that was still running returns to the FRONT — it was the head, so it
/// retries before everything that was behind it.
struct MessageQueue: Equatable, Sendable {
    private(set) var items: [QueuedPrompt] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var ids: [UUID] { items.map(\.id) }

    mutating func enqueue(_ prompt: QueuedPrompt) { items.append(prompt) }

    mutating func requeueFront(_ prompt: QueuedPrompt) { items.insert(prompt, at: 0) }

    mutating func dequeue() -> QueuedPrompt? {
        items.isEmpty ? nil : items.removeFirst()
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> QueuedPrompt? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Let a row go next (a click-to-insert that lost the race with the turn's
    /// end goes out as the next prompt instead).
    mutating func moveToFront(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        items.insert(items.remove(at: index), at: 0)
    }

    /// The minimum gap after a send bounced off a still-running turn, so a
    /// backend that stays busy is retried once a second, not once per
    /// round-trip (web `QUEUE_FLUSH_RETRY_BACKOFF_MS`).
    static let bounceBackoff: Duration = .seconds(1)

    /// How long the next flush waits: nothing after no recent bounce, the rest
    /// of the backoff after one. Never more than the backoff — a bounce stamped
    /// in the "future" (a clock oddity) counts as just now.
    static func flushDelay(sinceBounce elapsed: Duration?, backoff: Duration = bounceBackoff) -> Duration {
        guard let elapsed else { return .zero }
        let clamped = max(.zero, elapsed)
        return clamped >= backoff ? .zero : backoff - clamped
    }
}

/// Recognizers for the send path's recoverable rejections (web `turn-busy.ts`).
enum TurnRejection {
    /// `submit_session_feedback` found no turn to steer — the agent finished.
    static func isNoActiveTurn(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("no active turn")
    }

    /// The same, read off a thrown error: the backend's stable code, or its
    /// stable text for a server that predates the code.
    static func isNoActiveTurn(_ error: Error) -> Bool {
        if case APIError.server(_, let code, let message) = error {
            return code == "no_active_turn" || isNoActiveTurn(message)
        }
        return false
    }
}
