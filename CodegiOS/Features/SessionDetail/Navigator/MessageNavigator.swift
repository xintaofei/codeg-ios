import Foundation

// The message navigator (codeg 0.44, web `conversation-message-nav.tsx` /
// `message-nav-entries.ts` / `use-conversation-outline.ts` /
// `use-message-nav-jump.ts`): one row per user message of the WHOLE
// conversation — including the ones above the loaded window, which come from
// the backend's outline — and a jump to any of them. The logic lives here,
// pure; the view model owns the fetches and the paging.

// MARK: - Outline validity

/// Where a window starts, as the outline checks it: its offset and the
/// server's fingerprint of everything above it.
struct OutlineAnchor: Equatable, Hashable, Sendable {
    let offset: Int
    let prefixHash: String
}

extension OutlineAnchor {
    init(_ window: TranscriptWindow) {
        self.init(offset: window.offset, prefixHash: window.prefixHash)
    }
}

/// The outline the navigator holds and what it has been proven against.
///
/// Its turns are `full[0..<n)` for the `n` it was fetched for; `anchor` is the
/// window it provably describes the history above. The proof is the server's
/// own fingerprints, compared — never recomputed (the web extends its FNV
/// chain client-side; this port does not): accepted when the outline was cut
/// exactly at the window's start and fingerprints the same, then carried along
/// by every older page that joins the window under a seam proof. Anything
/// else that moves the window — a compaction's re-anchor, a fork's wholesale
/// replacement — leaves the anchor behind, and the outline is fetched again.
struct NavigatorOutline {
    var turns: [MessageTurn] = []
    var anchor: OutlineAnchor?
    /// The window an outline could not be had for — the fetch failed, or what
    /// came back didn't cover it. Not fetched again until the window moves or
    /// the user retries (web `failedKey`).
    var failedFor: OutlineAnchor?
    /// The window the fetch in flight is for.
    var inFlight: OutlineAnchor?
    /// Bumped whenever `turns` is replaced.
    var revision = 0

    /// The window an outline should be fetched for now, or nil: nothing is
    /// above it, the server has no outline route, or for this window one is
    /// held, failed, or already on its way. One for an OLDER window still in
    /// flight does not stop it — that one is replaced, and refused if it lands.
    func fetchKey(for window: TranscriptWindow?) -> OutlineAnchor? {
        guard let window, window.offset > 0, window.userTurnsBefore != nil else { return nil }
        let key = OutlineAnchor(window)
        guard anchor != key, failedFor != key, inFlight != key else { return nil }
        return key
    }

    /// ``fetchKey(for:)``, marked in flight.
    mutating func beginFetch(for window: TranscriptWindow?) -> OutlineAnchor? {
        guard let key = fetchKey(for: window) else { return nil }
        inFlight = key
        return key
    }

    /// A fetch for `key` came back — nil when it failed. Ignored (false) once
    /// it is not the fetch in flight any more: replaced by one for a newer
    /// window, or dropped with the screen. One that doesn't cover the window
    /// it was asked for (the prefix was rewritten in between) marks that
    /// window failed rather than being asked again (web `failedKey`).
    @discardableResult
    mutating func land(_ fetched: ConversationOutline?, for key: OutlineAnchor) -> Bool {
        guard inFlight == key else { return false }
        inFlight = nil
        if let fetched, OutlineValidity.accepts(fetched, for: key) {
            turns = fetched.turns
            anchor = key
            failedFor = nil
            revision &+= 1
        } else {
            failedFor = key
        }
        return true
    }

    /// An older page joined the window, moving its start from `before` to
    /// `after` (see ``OutlineValidity/anchorAfterPrepend(_:before:after:)``).
    mutating func windowDidPrepend(from before: OutlineAnchor, to after: OutlineAnchor) {
        anchor = OutlineValidity.anchorAfterPrepend(anchor, before: before, after: after)
    }

    /// The user asked again for a window that failed.
    mutating func retry() {
        failedFor = nil
    }

    /// The history above `window` the outline vouches for — nil when there is
    /// none to give (everything loaded) or it can't vouch (stale, loading).
    func earlierTurns(for window: TranscriptWindow?) -> [MessageTurn]? {
        guard let window, window.offset > 0,
              let proven = OutlineValidity.earlierTurns(turns, anchor: anchor, window: OutlineAnchor(window))
        else { return nil }
        return Array(proven)
    }

    func state(for window: TranscriptWindow?) -> NavigatorEarlier {
        NavigatorEarlier.state(window: window, outline: self)
    }
}

enum OutlineValidity {
    /// An outline fetched for the window at `requested` describes exactly the
    /// history above it.
    static func accepts(_ outline: ConversationOutline, for requested: OutlineAnchor) -> Bool {
        outline.turns.count == requested.offset && outline.prefixHash == requested.prefixHash
    }

    /// Where the anchor goes when an older page joins the window, moving it
    /// from `before` to `after`. The page's seam proof showed `full[0..<before)`
    /// is the history the outline was proven against, so the outline still
    /// covers the (shorter) history above the new start — but only an anchor
    /// that WAS the window's moves with it. One left behind by an earlier move
    /// stays behind.
    static func anchorAfterPrepend(_ anchor: OutlineAnchor?, before: OutlineAnchor,
                                   after: OutlineAnchor) -> OutlineAnchor? {
        anchor == before ? after : anchor
    }

    /// The history above `window` the outline provides, or nil when it can't
    /// vouch for it (stale: fetch again).
    static func earlierTurns(_ turns: [MessageTurn], anchor: OutlineAnchor?,
                             window: OutlineAnchor) -> ArraySlice<MessageTurn>? {
        guard anchor == window, turns.count >= window.offset else { return nil }
        return turns.prefix(window.offset)
    }
}

/// What the navigator can show of the messages above the loaded window.
enum NavigatorEarlier: Equatable, Sendable {
    /// Nothing is above the window (or there is no window: everything loaded).
    case allLoaded
    /// The server has no outline route; only the loaded messages are listed.
    case unsupported
    case loading
    /// The outline couldn't be had for this window — offer a retry.
    case failed
    case ready

    static func state(window: TranscriptWindow?, outline: NavigatorOutline) -> NavigatorEarlier {
        guard let window, window.offset > 0 else { return .allLoaded }
        guard window.userTurnsBefore != nil else { return .unsupported }
        let key = OutlineAnchor(window)
        if outline.anchor == key, outline.turns.count >= key.offset { return .ready }
        if outline.failedFor == key { return .failed }
        return .loading
    }
}

// MARK: - Paging through to a message

/// What one page of older history came to. Paging toward a message stops on
/// anything but `.committed`.
enum OlderPageOutcome: Equatable, Sendable {
    case committed
    /// Nothing is above the window (or no conversation / no window).
    case nothingOlder
    /// The request failed, or the page could not extend the window.
    case failed
    /// A newer transcript read took over, the window moved during the flight,
    /// or the screen's lifetime ended. Not a failure, and nothing committed.
    case superseded
    /// The prefix was rewritten under the window: the page could not join it.
    case seamBroken
}

enum OlderTurnsPaging {
    /// A normal page — and the least a jump asks for, so the message lands
    /// with some context above it.
    static let minimumPage = 120
    /// What the server clamps a page to anyway.
    static let maximumPage = 500

    /// The page to ask for when the window starts at `offset` and global turn
    /// `target` has to be loaded: everything down to it, within the bounds
    /// (web `loadOlderTurnsThrough`). The server aligns a page's start back to
    /// a user turn, so a target further up than one page takes several.
    static func limit(offset: Int, target: Int) -> Int {
        min(maximumPage, max(offset - target, minimumPage))
    }
}

/// A request for the transcript to bring a message to the top of the screen.
/// The token makes a second jump to the same message a new request.
struct TranscriptJumpRequest: Equatable, Sendable {
    let turnID: String
    let token: Int
}

// MARK: - Entries

/// One navigable user message.
struct MessageNavEntry: Identifiable, Equatable, Sendable {
    let turnID: String
    /// 1-based position among the conversation's user messages.
    let ordinal: Int
    /// The message's first text, trimmed (web `extractUserMessage`); nil when
    /// it has none (an image alone) — the row says "User message".
    let label: String?
    let sentAt: Date
    /// What the message's round changed: added / removed lines and distinct
    /// files across its replies' edit calls.
    let additions: Int
    let deletions: Int
    let fileCount: Int
    /// The global turn index of a message above the loaded window — what
    /// paging it in needs. Nil for a loaded one, which is scrolled to by id.
    let globalIndex: Int?

    var id: String { turnID }
}

enum MessageNavEntries {
    struct Input: Sendable {
        /// The history above the loaded window, `full[0..<offset)` (the
        /// outline, already proven against the window) — nil when it isn't
        /// available: everything is loaded, the server has no outline, or it
        /// is loading or failed.
        var earlierTurns: [MessageTurn]?
        /// User messages above the loaded window, listed or not.
        var earlierUserCount: Int
        /// The loaded transcript (and any message still on its way), in order.
        var loadedTurns: [MessageTurn]
    }

    /// One entry per user message (web `buildMessageNavEntries`): every one
    /// of the conversation when `earlierTurns` is given, otherwise the loaded
    /// ones, numbered on from the `earlierUserCount` above them so a message
    /// keeps its number whether or not the history above it is listed yet.
    ///
    /// The earlier and loaded turns are grouped as ONE transcript, so a round
    /// that straddles the window start (its prompt above, part of its reply
    /// loaded) still counts all of its edits.
    ///
    /// A message both lists hold is listed once, where the history puts it,
    /// and jumps to the loaded copy.
    ///
    /// Pure and actor-free: parsing every edit of a long history is real work,
    /// so callers run it off the main actor.
    static func build(_ input: Input) -> [MessageNavEntry] {
        let earlier = input.earlierTurns ?? []
        let turns = earlier.isEmpty ? input.loadedTurns : earlier + input.loadedTurns

        // Each user message of the outline at its global index.
        var outlineIndex: [String: Int] = [:]
        for (index, turn) in earlier.enumerated() where turn.role == .user {
            outlineIndex[turn.id] = index
        }
        let loadedUserIDs = Set(input.loadedTurns.lazy.filter { $0.role == .user }.map(\.id))

        var entries: [MessageNavEntry] = []
        var listed: Set<String> = []
        var ordinal = input.earlierTurns != nil ? 0 : input.earlierUserCount
        // Replies ahead of the first message belong to none.
        var start = 0
        while start < turns.count, turns[start].role != .user { start += 1 }
        while start < turns.count {
            var end = start + 1
            while end < turns.count, turns[end].role != .user { end += 1 }
            let message = turns[start]
            let roundStart = start
            start = end
            guard listed.insert(message.id).inserted else { continue }
            let loaded = loadedUserIDs.contains(message.id)
            let globalIndex = loaded ? nil : outlineIndex[message.id]
            guard loaded || globalIndex != nil else { continue }
            ordinal += 1
            let changes = roundChanges(turns[roundStart..<end])
            entries.append(MessageNavEntry(
                turnID: message.id,
                ordinal: ordinal,
                label: label(of: message),
                sentAt: message.timestamp,
                additions: changes.additions,
                deletions: changes.deletions,
                fileCount: changes.fileCount,
                globalIndex: globalIndex
            ))
        }
        return entries
    }

    /// A user message's first non-empty text, trimmed, cut at 80 characters
    /// the way the web cuts it.
    static func label(of turn: MessageTurn) -> String? {
        for block in turn.blocks {
            guard case .text(let text) = block, !text.isEmpty else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return trimmed.count > 80 ? String(trimmed.prefix(77)) + "..." : trimmed
        }
        return nil
    }

    struct RoundChanges: Equatable, Sendable {
        var additions = 0
        var deletions = 0
        var fileCount = 0
    }

    /// The tool names that change files (web `WRITE_OPS`).
    private static let writeOps: Set<String> = ["edit", "write", "apply_patch"]

    /// What a round's replies changed: every edit-like call's files, read the
    /// way the activity rows read them (``ActivityEdit/describeEditFiles(toolName:input:output:)``),
    /// with a file edited several times counted once.
    static func roundChanges(_ round: ArraySlice<MessageTurn>) -> RoundChanges {
        var changes = RoundChanges()
        var files: Set<String> = []
        for turn in round where turn.role == .assistant {
            for case let .toolUse(id, name, input, _, _) in turn.blocks {
                let tool = ToolNameNormalizer.normalizeToolName(name).lowercased()
                guard writeOps.contains(tool) else { continue }
                let output = firstUsableResult(in: turn.blocks, for: id)
                for file in ActivityEdit.describeEditFiles(toolName: tool, input: input, output: output) {
                    files.insert(file.path.replacingOccurrences(of: "\\", with: "/"))
                    changes.additions += file.additions ?? 0
                    changes.deletions += file.deletions ?? 0
                }
            }
        }
        changes.fileCount = files.count
        return changes
    }

    /// The output a call's diff is read from: its first result in the same
    /// turn that is not an error and says something (web
    /// `findToolResultOutput`) — the one the outline keeps.
    private static func firstUsableResult(in blocks: [ContentBlock], for id: String?) -> String? {
        guard let id else { return nil }
        for case let .toolResult(resultID, output, isError, _, _) in blocks
        where resultID == id && !isError {
            if let output, !output.isEmpty { return output }
        }
        return nil
    }
}
