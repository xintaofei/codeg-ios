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
    /// The reply this node belongs to and what folding the reply does to it;
    /// nil for nodes outside any reply (user prompts, system lines).
    var reply: ReplyMembership?
    /// For a reply's header: whether the reply is unfolded. Applied after the
    /// memoized build (`ReplyFolding.apply`), so folding never rebuilds it.
    var foldOpen: Bool = true
    /// For a reply's header: this reply is the current round (positional).
    var currentRound: Bool = false

    struct ReplyMembership {
        enum Role {
            /// The reply's header capsule.
            case header
            /// A process row: hidden while the reply is folded.
            case body
            /// A process row that can outlive the reply (a delegation or a
            /// sub-agent still running): kept in view while it is folded.
            case pinned
            /// The fold-back control under the rows: shown only while unfolded.
            case foot
        }
        let key: String
        let role: Role
    }

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
        case error(String, details: String?)
        case unsupported(String)
        // The activity timeline (codeg 0.44).
        /// A reply's header capsule: `Activity 14 steps · 1 failed · 3m 34s ›`.
        case replyHeader(ReplyHeader)
        /// The fold-back control at the foot of an unfolded reply.
        case replyFoot(ReplyHeader)
        /// The agent's reasoning between its calls, titled and folded.
        case thought(ActivityText, streaming: Bool)
        /// A folded run of explore / command calls.
        case activityGroup(kind: ActivityGroupKind, steps: [ActivityToolStep], status: StepStatus)
    }

    /// What a reply's header (and foot) say.
    struct ReplyHeader {
        let replyKey: String
        let summary: ActivitySummary
        let completed: Bool
        /// The reply can fold: it has process to hide and, once complete, an
        /// answer left to keep in view.
        let foldable: Bool
        let hasSteps: Bool
        let durationMs: Int?
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
        case .replyHeader: return .assistant(agent)
        case .replyFoot: return .footer
        case .thought: return .reasoning
        case .activityGroup(_, let steps, let status):
            return .toolGroup(error: status.isFailure || steps.contains { $0.tool.status.isFailure },
                              streaming: status.isLive)
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
    /// - Parameter inFlightUserTurnId: the server's affirmative statement that the
    ///   round opened by this user turn is running right now. The replies after it
    ///   are the only ones allowed to render an unfinished tool call as running —
    ///   everywhere else a `tool_use` with no result is a record of a call that
    ///   settled, not one still working. See `MessageRender.toolState`.
    /// - Parameter liveness: the floor applied to EVERY turn, for a transcript
    ///   that is being re-read while its session runs and has no round anchor of
    ///   its own (the sub-agent viewer). Left `.settled` by the main transcript,
    ///   which scopes liveness per-round via `inFlightUserTurnId` instead.
    static func buildPersisted(turns rawTurns: [MessageTurn], pending: [MessageTurn], agent: AgentType, suppressInFlight: Bool, inFlightUserTurnId: String? = nil, liveness: ToolLiveness = .settled) -> [TimelineNode] {
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

        // Where the running round begins, if it is loaded at all. Resolved on the
        // POST-suppression list so the index lines up with the walk below. Absent
        // (nil id, or a prompt that scrolled out of the loaded window) simply means
        // no turn is in the round — a missing anchor must never widen the scope.
        let inFlightIdx = inFlightUserTurnId.flatMap { id in
            turns.firstIndex { $0.role == .user && $0.id == id }
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
                // A failed round's closing line draws as the same failure node
                // the live turn showed, so the round reads the same before and
                // after it is reconciled — and a reopened session still says
                // why the round came back empty.
                let failure = turn.turnErrorText
                if !failure.isEmpty {
                    nodes.append(TimelineNode(id: turn.id, content: .error(failure, details: nil), agent: agent))
                } else if !SystemText.of(turn).isEmpty {
                // Skip system turns with no renderable text so the rail doesn't
                // show a lone marker against an empty row.
                    nodes.append(TimelineNode(id: turn.id, content: .system(turn), agent: agent, startsGroup: true))
                }
                i += 1
            case .assistant:
                var j = i + 1
                while j < turns.count, turns[j].role == .assistant { j += 1 }
                let merged = merge(Array(turns[i..<j]))
                let inRound = inFlightIdx.map { i > $0 } ?? false
                let replyLiveness: ToolLiveness = inRound ? .round : liveness
                // A reply in the running round is still being written (a reader
                // with no stream of its own); every other one is a record.
                nodes.append(contentsOf: replyNodes(
                    parts: MessageRender.adaptTurn(merged, liveness: replyLiveness, groupTools: false),
                    ownerID: merged.id, completed: replyLiveness != .round,
                    durationMs: merged.durationMs, agent: agent))
                nodes.append(TimelineNode(id: "\(merged.id)#footer",
                                          content: .footer(merged, questionID: lastUserID), agent: agent))
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

    // MARK: Live reply → nodes

    private static func liveNodes(_ live: LiveTurn, agent: AgentType) -> [TimelineNode] {
        var out: [TimelineNode] = []
        if !live.livePlan.isEmpty {
            out.append(TimelineNode(id: "\(live.id)#plan", content: .plan(live.livePlan, streaming: live.isStreaming), agent: agent))
        }
        if live.isEmpty && live.isStreaming {
            out.append(TimelineNode(id: "\(live.id)#thinking", content: .thinking, agent: agent))
        }
        out.append(contentsOf: replyNodes(
            parts: MessageRender.adaptLive(live, groupTools: false),
            ownerID: live.id, completed: !live.isStreaming, durationMs: nil, agent: agent))
        if let error = live.errorMessage {
            out.append(TimelineNode(id: "\(live.id)#error",
                                    content: .error(error, details: live.errorDetails), agent: agent))
        }
        return out
    }

    // MARK: Reply → activity nodes

    /// One reply as the activity timeline draws it (web `CompletedTurnContent`):
    /// its header capsule, its process rows, the fold-back foot, then the
    /// trailing answer, which stays in view when the reply folds. Every node is
    /// tagged with the reply and its role; WHICH of them show is decided after
    /// the memoized build, by `ReplyFolding.apply`.
    private static func replyNodes(parts: [RenderPart], ownerID: String, completed: Bool,
                                   durationMs: Int?, agent: AgentType) -> [TimelineNode] {
        // A reply still being written keeps its closing prose on the rail: what
        // will turn out to be the answer is not known yet.
        let model = BuildActivity.build(parts, isStreaming: !completed, keepAnswer: !completed)
        let bodyCount = parts.count - model.answer.count
        // Nothing but an empty answer: no header, just what there is.
        if completed, bodyCount == 0, !BuildActivity.hasVisibleAnswer(model.answer) {
            return parts.enumerated().map { idx, part in node(for: part, ownerID: ownerID, index: idx, agent: agent) }
        }
        // Folding trades the process away to keep the answer, so a reply with no
        // answer left (stopped mid-call, or whose last card IS the answer)
        // settles un-foldable. A live reply is exempt from the answer half: its
        // closing prose has not been written yet.
        let foldable = bodyCount > 0 && (!completed || BuildActivity.hasVisibleAnswer(model.answer))
        let header = TimelineNode.ReplyHeader(
            replyKey: ownerID, summary: model.summary, completed: completed,
            foldable: foldable, hasSteps: !model.items.isEmpty, durationMs: durationMs)
        func member(_ node: TimelineNode, _ role: TimelineNode.ReplyMembership.Role) -> TimelineNode {
            var tagged = node
            tagged.reply = .init(key: ownerID, role: role)
            return tagged
        }

        var out: [TimelineNode] = [member(
            TimelineNode(id: "\(ownerID)#header", content: .replyHeader(header), agent: agent), .header)]
        for item in model.items {
            out.append(member(node(for: item, ownerID: ownerID, agent: agent),
                              canOutliveReply(item) ? .pinned : .body))
        }
        if foldable {
            out.append(member(TimelineNode(id: "\(ownerID)#foot", content: .replyFoot(header), agent: agent), .foot))
        }
        for (offset, part) in model.answer.enumerated() {
            out.append(node(for: part, ownerID: ownerID, index: bodyCount + offset, agent: agent))
        }
        return out
    }

    /// Rows that can outlive their reply — kept in view when it folds, while
    /// they are still live.
    private static func canOutliveReply(_ item: ActivityItem) -> Bool {
        guard case .step(let step) = item else { return false }
        switch step {
        case .delegationPolls(_, _, let status):
            return status.isLive
        case .tool(let tool):
            switch tool.tool.kind {
            case .delegation, .delegationResume, .delegationStatus, .agent: return tool.tool.status.isLive
            default: return false
            }
        default:
            return false
        }
    }

    private static func node(for item: ActivityItem, ownerID: String, agent: AgentType) -> TimelineNode {
        switch item {
        case .group(_, let kind, let steps, let status):
            // Keyed like the older tool group (its first call), so the row keeps
            // its identity while the run grows and across the live → history
            // hand-over.
            let gid = steps.first.map { "toolgroup-\($0.call.id)" } ?? "\(ownerID)#group"
            return TimelineNode(id: gid, content: .activityGroup(kind: kind, steps: steps, status: status), agent: agent)
        case .step(let step):
            return node(for: step, ownerID: ownerID, agent: agent)
        }
    }

    private static func node(for step: ActivityStep, ownerID: String, agent: AgentType) -> TimelineNode {
        let base = "\(ownerID)#\(BuildActivity.rowIdentity(step.key))"
        switch step {
        case .tool(let tool):
            return TimelineNode(id: "tool-\(tool.call.id)", content: .tool(tool.call), agent: agent)
        case .thought(_, let text, let streaming):
            if case .live(let run, _) = text {
                return TimelineNode(id: "k-\(run.id)", content: .thought(text, streaming: streaming), agent: agent)
            }
            return TimelineNode(id: base, content: .thought(text, streaming: streaming), agent: agent)
        case .note(_, .text(.settled(let s))):
            return TimelineNode(id: base, content: .assistantText(s), agent: agent)
        case .note(_, .text(.live(let run, let streaming))):
            return TimelineNode(id: "t-\(run.id)", content: .liveText(run, streaming: streaming), agent: agent)
        case .note(_, .turnError(let message)):
            return TimelineNode(id: base, content: .error(message, details: nil), agent: agent)
        case .image(_, let image, let caption):
            return TimelineNode(id: base, content: .image(image, caption: caption), agent: agent)
        case .plan(_, let entries, let streaming):
            return TimelineNode(id: base, content: .plan(entries, streaming: streaming), agent: agent)
        case .delegationPolls(_, let polls, _):
            let gid = polls.first.map { "delegstatus-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .delegationStatusGroup(polls), agent: agent)
        case .taskList(_, let ops):
            let gid = ops.first.map { "taskgroup-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .taskGroup(ops), agent: agent)
        case .compaction(_, let before, let after, let running):
            return TimelineNode(id: base, content: .compaction(before: before, after: after, running: running), agent: agent)
        case .unsupported(_, let type):
            return TimelineNode(id: base, content: .unsupported(type), agent: agent)
        }
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
        case .turnError(let message):
            return TimelineNode(id: base, content: .error(message, details: nil), agent: agent)
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
