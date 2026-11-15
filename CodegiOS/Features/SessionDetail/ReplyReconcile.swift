import Foundation

/// When a transcript read may replace a reply this screen streamed: the
/// post-turn reconcile (`refreshAfterTurn`) and the lost-connection one
/// (`reconcileOrFail`).
///
/// The server emits `turn_complete` a beat before the agent's last transcript
/// write lands (codeg 0.44 measures ~8ms, and the web no longer re-reads at
/// all — see `completeTurn` in `conversation-runtime-store.ts`). A read in
/// that gap ends on the reply's last tool call with its closing words not
/// written yet. That is an assistant turn with content, which used to pass,
/// and adopting it dropped the final answer until the session was reopened.
///
/// So a read must also carry the reply's closing words: the end of the last
/// prose the reply streamed. One that doesn't is retried; when none ever
/// does, the streamed copy stays (`promoteUnreconciled`), as on the web.
enum ReplyReconcile {
    /// How much of the closing prose a read must hold, in letters and digits.
    /// Enough that an earlier sentence can't stand in for it by accident.
    static let evidenceLength = 64

    /// Where the round being reconciled begins, as the screen knows it.
    enum RoundAnchor: Equatable {
        /// At this global index: every loaded turn before it is the server's
        /// own, so the count is the server's too.
        case at(Int)
        /// After rounds this screen folded in itself from global index `from`
        /// on (`promoteUnreconciled`). The server may hold those as more turns
        /// than the stream's copy, or fewer, and nothing in a read says which
        /// of its user turns is this round's prompt: a steered note can be
        /// persisted as one, a prompt stopped before it was sent is not. So no
        /// index past `from` is known, and the round is found by its prompt.
        case unplaced(from: Int, prompt: PromptMatch)
    }

    /// How an `unplaced` round's prompt is told apart in a read.
    enum PromptMatch: Equatable {
        /// The prompt wasn't this screen's to send (a watched turn).
        case notOurs
        /// The words of the prompt this screen sent (`promptWords(of:)`),
        /// which no folded user turn holds.
        case words([String])
        /// This screen sent it, but nothing in a read can tell it from a
        /// folded turn: a folded prompt or note says the same words (a prompt
        /// re-sent, perhaps after one stopped before it went out), or it has
        /// none (an image alone).
        case unidentifiable
    }

    /// How to find this round's prompt, given the user turn this screen sent
    /// it as (nil when the round isn't its send) and the turns folded in so far.
    static func promptMatch(sent: MessageTurn?, folded: some Collection<MessageTurn>) -> PromptMatch {
        guard let sent else { return .notOurs }
        guard let words = promptWords(of: text(of: [sent][...], role: .user)) else { return .unidentifiable }
        let said = folded.contains { turn in
            turn.role == .user && holdsInOrder(normalized(text(of: [turn][...], role: .user)), words)
        }
        return said ? .unidentifiable : .words(words)
    }

    /// Where in `turns` (a read whose first turn sits at global `offset`) the
    /// round `anchor` names begins — or nil when the read hasn't reached it,
    /// or can't be judged yet.
    ///
    /// An `unplaced` round is judged only once the agent's writes have
    /// `settled`: right at the turn's end a read can stop at this round's
    /// last tool call. Settled, the round is what follows its prompt — the
    /// last user turn in the folded span that says it, when the screen sent
    /// one, so user turns after it (notes steered into this round) are this
    /// round's, and a read that doesn't hold the prompt yet can't lend this
    /// round an earlier one. A prompt a folded turn also says can't be found
    /// that way, and isn't placed at all (`PromptMatch`). Without a prompt of
    /// its own, what follows the read's last user turn (`lastRoundStart`).
    /// And the read must still have grown past what is loaded (`loadedEnd`) —
    /// the old test, kept as the floor.
    static func roundStart(in turns: [MessageTurn], offset: Int, anchor: RoundAnchor,
                           loadedEnd: Int, settled: Bool) -> Int? {
        let globalEnd = offset + turns.count
        switch anchor {
        case .at(let index):
            guard globalEnd > index else { return nil }
            return min(max(index - offset, 0), turns.count)
        case .unplaced(let from, let match):
            guard settled, globalEnd > loadedEnd else { return nil }
            let prompt: [String]
            switch match {
            case .notOurs: return lastRoundStart(in: turns, offset: offset, from: from)
            case .unidentifiable: return nil
            case .words(let words): prompt = words
            }
            let start = min(max(from - offset, 0), turns.count)
            let promptAt = turns.indices[start...].last { index in
                turns[index].role == .user
                    && holdsInOrder(normalized(text(of: turns[index...index], role: .user)), prompt)
            }
            return promptAt.map { $0 + 1 }
        }
    }

    /// Where the read's newest round begins, looking no earlier than global
    /// index `from`: just after its last user turn. A steered note persisted
    /// as a user turn starts it later than the prompt — which can only cost a
    /// match, never lend one from an earlier round.
    static func lastRoundStart(in turns: [MessageTurn], offset: Int, from: Int) -> Int {
        let start = min(max(from - offset, 0), turns.count)
        let lastUser = turns.indices[start...].last { turns[$0].role == .user }
        return lastUser.map { $0 + 1 } ?? start
    }

    /// What a read has to contain to hold `text` — for a reply, the last prose
    /// run it streamed; for a prompt, what was sent: its last letters and
    /// digits, lowercased. Nil when there is no such evidence to ask for — no
    /// text, or text with neither — and the read's shape alone decides.
    ///
    /// Letters and digits only, because the stream and the agent's own record
    /// of it are the same words but not always the same bytes: a split into
    /// blocks, line ends, a stray space, a command wrapped in tags.
    static func evidence(of text: String?) -> String? {
        guard let text else { return nil }
        let letters = normalized(text)
        return letters.isEmpty ? nil : String(letters.suffix(evidenceLength))
    }

    /// Whether a read (`turns`, from the response) holds the round that just
    /// ended here, so it may replace what streamed.
    ///
    /// - It has to end on that round: an assistant turn with content, or a
    ///   failure line — which only counts when this round failed too, as
    ///   otherwise it is an earlier round's (web `parseHoldsTheLatestRound`).
    /// - Ending on a reply, it also has to hold `evidence` (see above) in an
    ///   assistant turn's text from `roundStart` on (`roundStart(in:…)`), so
    ///   nothing an earlier round said counts.
    static func holdsReply(_ turns: [MessageTurn], roundStart: Int,
                           localRoundFailed: Bool, evidence: String?) -> Bool {
        guard let last = turns.last else { return false }
        if last.isTurnErrorTurn { return localRoundFailed }
        guard last.role == .assistant, last.blocks.contains(where: \.isRenderable) else { return false }
        guard let evidence else { return true }
        return holdsProse(turns, from: roundStart, evidence: evidence)
    }

    /// What a user turn has to contain to be the prompt `text`: its last
    /// words, letters and digits only, to be found in order — an agent may
    /// record a prompt wrapped (a command in tags) or with context around it,
    /// but not with its words reordered. Nil for a prompt without words (an
    /// image alone).
    static func promptWords(of text: String?) -> [String]? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { String(normalized(String($0)).suffix(evidenceLength)) }
            .filter { !$0.isEmpty }
        return words.isEmpty ? nil : Array(words.suffix(12))
    }

    private static func holdsInOrder(_ haystack: String, _ words: [String]) -> Bool {
        var rest = haystack[...]
        for word in words {
            guard let found = rest.range(of: word) else { return false }
            rest = rest[found.upperBound...]
        }
        return true
    }

    /// Whether the assistant text of `turns` from index `start` on holds
    /// `evidence` (see `evidence(of:)`).
    static func holdsProse(_ turns: [MessageTurn], from start: Int, evidence: String) -> Bool {
        let start = min(max(start, 0), turns.count)
        return normalized(text(of: turns[start...], role: .assistant)).contains(evidence)
    }

    /// The text blocks of the `role` turns in `turns`, joined.
    private static func text(of turns: ArraySlice<MessageTurn>, role: TurnRole) -> String {
        turns.filter { $0.role == role }
            .flatMap(\.blocks)
            .compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }
            .joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

private extension ContentBlock {
    /// Whether the block draws as something (an empty text run, or an image
    /// generation with neither prompt nor image, does not).
    var isRenderable: Bool {
        switch self {
        case .text(let t), .thinking(let t):
            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .toolUse, .toolResult, .turnError, .unknown:
            return true
        case .imageGeneration(let prompt, let image):
            return image != nil || !(prompt ?? "").isEmpty
        }
    }
}

extension LiveTurn {
    /// The reply's last run of prose (not reasoning, not a sub-agent's), the
    /// part a read that caught up with it must hold (`ReplyReconcile`).
    var closingProse: String? {
        for segment in segments.reversed() {
            if case .text(let run) = segment,
               !run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return run.fullText
            }
        }
        return nil
    }
}
