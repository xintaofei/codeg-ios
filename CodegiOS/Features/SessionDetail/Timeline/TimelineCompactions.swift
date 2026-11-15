import Foundation

// Where a context compaction goes on the timeline (codeg 0.44, web
// `message-list-view.tsx`; Android 52f2021): between turns when no reply goes
// on after it, as a step of the reply when one does, and once however many
// copies of it reach the thread.

extension TranscriptTimeline {
    // MARK: Turns that render nothing

    /// A turn with nothing to draw — the empty placeholders parsers leave
    /// between a reply's turns, which do not cut it in two (web
    /// `isEmptyTurnItem`). A failed round's closing line is not one: it draws
    /// as the failure.
    static func rendersNothing(_ turn: MessageTurn) -> Bool {
        switch turn.role {
        case .system:
            return turn.turnErrorText.isEmpty && SystemText.of(turn).isEmpty
        case .user, .assistant:
            return turn.blocks.allSatisfy { block in
                switch block {
                case .text(let t), .thinking(let t):
                    return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default:
                    return false
                }
            }
        }
    }

    /// Where the reply that starts at `start` (an assistant turn) ends — the
    /// index after its last assistant turn. It runs on through its assistant
    /// turns and through the empty placeholders between them, but not into a
    /// compaction it does not go on after, which stands between turns.
    static func replyEnd(_ turns: [MessageTurn], from start: Int) -> Int {
        var j = start + 1
        var end = j
        while j < turns.count {
            let next = turns[j]
            if next.role == .assistant {
                if hoistsCompaction(turns, at: j) { break }
                j += 1
                end = j
            } else if rendersNothing(next) {
                j += 1
            } else {
                break
            }
        }
        return end
    }

    // MARK: Compactions between turns

    /// A turn holding one compaction call (and its result) and nothing else
    /// but blank text.
    static func isCompactionOnly(_ turn: MessageTurn) -> Bool {
        guard turn.role == .assistant else { return false }
        var found = false
        var callID: String?
        for block in turn.blocks {
            switch block {
            case .text(let t), .thinking(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .toolUse(let id, _, _, _, let meta):
                if found || !ContextCompaction.matches(meta) { return false }
                found = true
                callID = id
            case .toolResult(let id, _, _, _, _):
                // Its result, and no other call's.
                if !found { return false }
                if let id, id != callID { return false }
            default:
                return false
            }
        }
        return found
    }

    /// Whether the turn at `index` is a compaction drawn as a divider between
    /// turns rather than as a step of a reply (web `hoistedCompaction`): it
    /// holds nothing else, and no reply goes on after it — the next turn with
    /// anything in it, past empty placeholders and other compactions, is not
    /// the agent's.
    ///
    /// An agent that compacts its context by itself mid-turn (codex, claude)
    /// goes on with the same reply, and live the compaction is one of that
    /// reply's steps; hoisted out, it would cut the reply in two, each half
    /// with its own header and footer. A `/compact` between replies, or one at
    /// the very end, is the divider between them — merged into the reply
    /// before it, it took the place of that reply's answer.
    static func hoistsCompaction(_ turns: [MessageTurn], at index: Int) -> Bool {
        guard isCompactionOnly(turns[index]) else { return false }
        for next in turns[(index + 1)...] {
            if rendersNothing(next) { continue }
            if next.role != .assistant { return true }
            if !isCompactionOnly(next) { return false }
        }
        return true
    }

    /// A compaction-only turn → its divider, under the id its part would have
    /// in a headerless reply (`<turn id>#<part index>`).
    static func compactionDivider(_ turn: MessageTurn, liveness: ToolLiveness,
                                  agent: AgentType) -> [TimelineNode] {
        let parts = MessageRender.adaptTurn(turn, liveness: liveness)
        for (index, part) in parts.enumerated() {
            if case .compaction(let info) = part {
                return [compactionNode(info, id: "\(turn.id)#\(index)", agent: agent)]
            }
        }
        return []
    }

    /// A compaction standing between turns: a row of its own, in no reply, so
    /// folding never hides it — and a turn boundary, like a prompt.
    static func compactionNode(_ info: CompactionInfo, id: String, agent: AgentType) -> TimelineNode {
        TimelineNode(id: id, content: .compaction(info), agent: agent, startsGroup: true)
    }

    // MARK: One compaction, drawn once

    /// Drop repeat renderings of one compaction divider, keeping the first
    /// (web `dedupeCompactionItems`). Run on the persisted and live tiers
    /// joined — before folding, and outside the persisted memo.
    ///
    /// A compaction reaches the thread through two channels: the live call,
    /// and the agent's own transcript under its parser's id. Mid-turn both
    /// can be in hand, and the in-flight suppression cannot hide the
    /// transcript's copy: a `/compact` prompt is persisted only after the
    /// boundary (claude), or never (codex), so there is no in-flight prompt to
    /// anchor on. Either of two identities is enough — the call id where both
    /// copies name the event alike (codex), the figures where they do not
    /// (``ContextCompaction/eventKey(_:)``). codex's bare markers name no
    /// event by their figures, so separate ones under separate ids stay
    /// separate.
    ///
    /// Only the dividers between turns are compared; a compaction inside a
    /// reply is one of its steps. Returns `nodes` itself when nothing repeats,
    /// which is every pass but the rare one — so the common path allocates
    /// nothing.
    static func dedupeCompactions(_ nodes: [TimelineNode]) -> [TimelineNode] {
        func standalone(_ node: TimelineNode) -> CompactionInfo? {
            guard node.reply == nil, case .compaction(let info) = node.content else { return nil }
            return info
        }
        var dividers = 0
        for node in nodes where standalone(node) != nil {
            dividers += 1
            if dividers > 1 { break }
        }
        guard dividers > 1 else { return nodes }

        var seen = Set<String>()
        var dropped = false
        let kept = nodes.filter { node in
            guard let info = standalone(node) else { return true }
            let keys = [info.eventKey, info.callID.map { "call:\($0)" }].compactMap { $0 }
            let isRepeat = keys.contains { seen.contains($0) }
            // A repeat's other identity names the same event too, so it is
            // recorded even though the node itself goes.
            seen.formUnion(keys)
            if isRepeat { dropped = true }
            return !isRepeat
        }
        return dropped ? kept : nodes
    }
}
