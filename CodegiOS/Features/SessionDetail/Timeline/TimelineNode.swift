import SwiftUI

/// One node on the transcript timeline. The whole transcript — persisted turns,
/// optimistic pending user turns, and the live streaming turn — flattens into a
/// single `[TimelineNode]`, and `TranscriptView`'s `List` renders one row each.
///
/// `id` is the row's stable identity (for `List` recycling, scroll-to-id, and the
/// jump-to-question affordance) — see `TranscriptTimeline` for the scheme. The
/// struct is deliberately NOT `Equatable`: `Content` carries reference types
/// (`LiveTextRun`) whose value never changes identity across a stream, so any
/// value-equality gating would suppress needed re-renders. Identity comes from
/// `id`; live re-rendering comes from `@Observable` read at the leaf.
struct TimelineNode: Identifiable {
    let id: String
    let content: Content
    /// The session's agent, used to render the agent-branded marker on assistant
    /// nodes (the rail reintroduces agent identity in the gutter without spending
    /// any content width).
    let agent: AgentType
    /// Whether the spine continues above / below this node. Suppressed only at the
    /// very first and very last node so the rail terminates at its endpoints.
    var connectTop: Bool = true
    var connectBottom: Bool = true
    /// A reply boundary begins here (user / system nodes) — used for slightly
    /// larger breathing room before a new turn.
    var startsGroup: Bool = false

    enum Content {
        case user(MessageTurn)
        case system(MessageTurn)
        case assistantText(String)
        case liveText(LiveTextRun, streaming: Bool)
        case reasoning(String)
        case liveReasoning(LiveTextRun, streaming: Bool)
        case tool(ToolCallVM)
        case toolGroup([ToolCallVM], streaming: Bool)
        case delegationStatusGroup([ToolCallVM])
        case taskGroup([ToolCallVM])
        case image(ImageData, caption: String?)
        /// A context-compaction boundary — rendered as a chrome-less divider, not
        /// a card. Token counts are Grok-only (codex sends none).
        case compaction(before: Int?, after: Int?, running: Bool)
        case footer(MessageTurn, questionID: String?)
        case plan([PlanEntry], streaming: Bool)
        case thinking
        case error(String)
        case unsupported(String)
    }

    /// The gutter marker for this node — drives the icon and the state tint.
    var marker: MarkerKind {
        switch content {
        case .user: return .user
        case .system: return .system
        case .assistantText, .liveText: return .assistant(agent)
        case .reasoning, .liveReasoning: return .reasoning
        case .tool(let vm): return .tool(icon: vm.icon, state: vm.state)
        case .toolGroup(let items, let streaming):
            return .toolGroup(error: items.contains(where: \.isError), streaming: streaming)
        case .delegationStatusGroup(let polls):
            let running = polls.contains { $0.state == .running || $0.state == .inputStreaming }
            let state: ToolCallState = running ? .running : (polls.contains(where: \.isError) ? .error : .done)
            return .tool(icon: "person.2", state: state)
        case .taskGroup(let ops):
            let running = ops.contains { $0.state == .running || $0.state == .inputStreaming }
            let state: ToolCallState = running ? .running : (ops.contains(where: \.isError) ? .error : .done)
            return .tool(icon: "checklist", state: state)
        case .image: return .image
        case .compaction: return .compaction
        case .footer: return .footer
        case .plan: return .plan
        case .thinking: return .thinking
        case .error: return .error
        case .unsupported: return .system
        }
    }
}

// MARK: - Builder

/// Flattens the transcript into `[TimelineNode]`. Reuses the same primitives the
/// old turn-based layout did — consecutive assistant turns are merged into one
/// reply (`merge`), then expanded into ordered parts by `MessageRender.adaptTurn`
/// — so grouping, tool pairing, and the value-keyed render cache all keep working;
/// only the *shell* changed from per-turn blocks to per-part rail nodes.
///
/// `@MainActor` because it reads the main-actor `MessageRender` / `LiveTurn`. Only
/// ever called from a view body, so this is free.
@MainActor
enum TranscriptTimeline {
    /// Build the **persisted** node tier — the expensive half. Flattens persisted
    /// turns + optimistic pending user turns into nodes. Deliberately does NOT read
    /// the live turn and does NOT apply the rail-endpoint (`connectTop`/`Bottom`)
    /// fixup: the caller concatenates the live tier and terminates the rail on the
    /// *combined* list, so the tail's `connectBottom` lands on the live node while a
    /// reply streams. This half is memoized by the transcript (keyed on a cheap
    /// content-free signal), because `MessageRender.adaptTurn`'s value-keyed cache
    /// hashes each `MessageTurn`'s full content on lookup — work we must not repeat
    /// per streamed token.
    ///
    /// - Parameter suppressInFlight: set when a reattach live turn owns the
    ///   in-flight reply. The snapshot's `live_message` is the COMPLETE reply, but
    ///   the agent CLI asynchronously persists a PARTIAL copy of that same reply
    ///   into `turns` while it streams — so the persisted assistant turns after the
    ///   most recent user prompt are dropped here to avoid double-rendering the reply
    ///   beside the live stream. Mirrors the web client's `getTimelineTurns`
    ///   in-flight suppression. A no-op on the send path (the optimistic prompt is in
    ///   `pending`, not `turns`, so there are no trailing persisted assistant turns).
    static func buildPersisted(turns rawTurns: [MessageTurn], pending: [MessageTurn], agent: AgentType, suppressInFlight: Bool) -> [TimelineNode] {
        var nodes: [TimelineNode] = []

        // Hide the persisted partial in-flight reply while the reattach live turn
        // (which carries the full reply) is in hand: drop the assistant turns that
        // follow the most recent user prompt. Earlier replies stay untouched.
        let turns: [MessageTurn]
        if suppressInFlight,
           let promptIdx = rawTurns.lastIndex(where: { $0.role == .user }) {
            turns = rawTurns.enumerated()
                .filter { $0.offset <= promptIdx || $0.element.role != .assistant }
                .map(\.element)
        } else {
            turns = rawTurns
        }

        // Persisted turns. User/system map 1:1; runs of consecutive assistant
        // turns merge into one reply (codeg persists a single logical reply as
        // several turns), then expand into part nodes + a footer.
        var lastUserID: String?
        var i = 0
        while i < turns.count {
            let turn = turns[i]
            switch turn.role {
            case .user:
                lastUserID = turn.id
                nodes.append(TimelineNode(id: turn.id, content: .user(turn), agent: agent, startsGroup: true))
                i += 1
            case .system:
                // Skip system turns with no renderable text so the rail doesn't
                // show a lone marker against an empty row.
                if !SystemText.of(turn).isEmpty {
                    nodes.append(TimelineNode(id: turn.id, content: .system(turn), agent: agent, startsGroup: true))
                }
                i += 1
            case .assistant:
                var j = i + 1
                while j < turns.count, turns[j].role == .assistant { j += 1 }
                let merged = merge(Array(turns[i..<j]))
                nodes.append(contentsOf: assistantNodes(merged: merged, questionID: lastUserID, agent: agent))
                i = j
            }
        }

        // Optimistic user turns (sent, not yet reconciled into `turns`).
        for turn in pending {
            nodes.append(TimelineNode(id: turn.id, content: .user(turn), agent: agent, startsGroup: true))
        }

        return nodes
    }

    /// Build the **live** node tier — the in-flight reply. Cheap (O(segments); text
    /// nodes wrap the `LiveTextRun` reference, copying no prose), so the caller
    /// rebuilds it fresh on every pass while the persisted tier stays memoized. That
    /// freshness is required for correctness, not just latency: live tool cards,
    /// gutter markers, and plan statuses mutate their `LiveToolCall`/`LiveTurn` in
    /// place and render from a value snapshot with no observing leaf, so a stale
    /// live tier would freeze them at their first-rendered state.
    static func buildLive(_ live: LiveTurn, agent: AgentType) -> [TimelineNode] {
        liveNodes(live, agent: agent)
    }

    // MARK: Assistant reply → nodes

    private static func assistantNodes(merged: MessageTurn, questionID: String?, agent: AgentType) -> [TimelineNode] {
        var out = MessageRender.adaptTurn(merged).enumerated().map { idx, part in
            node(for: part, ownerID: merged.id, index: idx, agent: agent)
        }
        // The footer (reply time / model / tokens / copy / jump) is always emitted
        // — even when the reply has no renderable parts — so an empty or tool-only
        // turn still shows its metadata instead of vanishing.
        out.append(TimelineNode(id: "\(merged.id)#footer", content: .footer(merged, questionID: questionID), agent: agent))
        return out
    }

    private static func liveNodes(_ live: LiveTurn, agent: AgentType) -> [TimelineNode] {
        var out: [TimelineNode] = []
        if !live.livePlan.isEmpty {
            out.append(TimelineNode(id: "\(live.id)#plan", content: .plan(live.livePlan, streaming: live.isStreaming), agent: agent))
        }
        out.append(contentsOf: MessageRender.adaptLive(live).enumerated().map { idx, part in
            node(for: part, ownerID: live.id, index: idx, agent: agent)
        })
        // The "waiting" shimmer sits at the TAIL, after whatever has arrived so
        // far: nothing has, or the user interrupted and the agent hasn't answered
        // yet. (With no parts it lands exactly where it always did.)
        if live.isStreaming && live.isAwaitingOutput {
            out.append(TimelineNode(id: "\(live.id)#thinking", content: .thinking, agent: agent))
        }
        if let error = live.errorMessage {
            out.append(TimelineNode(id: "\(live.id)#error", content: .error(error), agent: agent))
        }
        return out
    }

    // MARK: Part → node

    /// Map one `RenderPart` to a node. IDs are chosen so a tool that is `running`
    /// during streaming keeps the SAME `List` identity once the reply finalizes
    /// (both paths key tools by their ACP tool id) — its card's expand state and
    /// marker survive the live→persisted handoff instead of flashing. Text /
    /// reasoning live runs key by the segment id (`t-`/`k-`), matching
    /// `LiveSegment.id`; finalized prose keys by its part index.
    private static func node(for part: RenderPart, ownerID: String, index: Int, agent: AgentType) -> TimelineNode {
        let base = "\(ownerID)#\(index)"
        switch part {
        case .text(let s):
            return TimelineNode(id: base, content: .assistantText(s), agent: agent)
        case .reasoning(let t):
            return TimelineNode(id: base, content: .reasoning(t), agent: agent)
        case .liveText(let run, let streaming):
            return TimelineNode(id: "t-\(run.id)", content: .liveText(run, streaming: streaming), agent: agent)
        case .liveReasoning(let run, let streaming):
            return TimelineNode(id: "k-\(run.id)", content: .liveReasoning(run, streaming: streaming), agent: agent)
        case .userMessage(let turn):
            // Keyed by the feedback note (`turn.id` is "u-<note id>"), not the
            // part index, so the row keeps its identity as the reply grows past
            // it. `startsGroup` matches a persisted user turn: interrupting the
            // agent begins a new exchange.
            return TimelineNode(id: turn.id, content: .user(turn), agent: agent, startsGroup: true)
        case .tool(let vm):
            return TimelineNode(id: "tool-\(vm.id)", content: .tool(vm), agent: agent)
        case .toolGroup(let items, let streaming):
            let gid = items.first.map { "toolgroup-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .toolGroup(items, streaming: streaming), agent: agent)
        case .delegationStatusGroup(let polls):
            let gid = polls.first.map { "delegstatus-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .delegationStatusGroup(polls), agent: agent)
        case .taskGroup(let ops):
            let gid = ops.first.map { "taskgroup-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .taskGroup(ops), agent: agent)
        case .image(let img, let cap):
            return TimelineNode(id: base, content: .image(img, caption: cap), agent: agent)
        case .compaction(let before, let after, let running):
            return TimelineNode(id: base,
                                content: .compaction(before: before, after: after, running: running),
                                agent: agent)
        case .unknown(let type):
            return TimelineNode(id: base, content: .unsupported(type), agent: agent)
        }
    }

    // MARK: Merge (ported from the old TranscriptGrouping)

    /// Concatenate a run of assistant turns into one synthetic reply. Metadata is
    /// consolidated so the single footer reads correctly: tokens / duration summed,
    /// model + completion time from the last turn. Deterministic (no `Date()`), so
    /// the merged value is stable across rebuilds and `MessageRender.adaptTurn`'s
    /// value-keyed cache keeps hitting.
    static func merge(_ group: [MessageTurn]) -> MessageTurn {
        guard group.count > 1 else { return group[0] }
        let usages = group.compactMap(\.usage)
        let mergedUsage: TurnUsage? = usages.isEmpty ? nil : TurnUsage(
            inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
            outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
            cacheCreationInputTokens: usages.reduce(0) { $0 + $1.cacheCreationInputTokens },
            cacheReadInputTokens: usages.reduce(0) { $0 + $1.cacheReadInputTokens }
        )
        let durations = group.compactMap(\.durationMs)
        return MessageTurn(
            id: group[0].id,
            role: .assistant,
            blocks: group.flatMap(\.blocks),
            timestamp: group[0].timestamp,
            usage: mergedUsage,
            durationMs: durations.isEmpty ? nil : durations.reduce(0, +),
            model: group.last(where: { $0.model?.isEmpty == false })?.model ?? group[0].model,
            completedAt: group.last?.completedAt ?? group.last?.timestamp
        )
    }
}
