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
    /// The session's agent, used to render the agent-branded marker on a
    /// reply's header (the rail carries agent identity in the gutter without
    /// spending any content width).
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
    /// For a persisted reply's footer: where "Fork from here" would fork (the
    /// reply's LAST turn — the merged turn keeps the first one's id). Nil
    /// everywhere else, and wherever the builder wasn't asked for fork points.
    var forkPoint: ReplyForkPoint?

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
            /// The answer (or a reply with no header at all): always shown.
            /// Tagged so the newest reply is found even when it has no header.
            case always
        }
        let key: String
        let role: Role
    }

    enum Content {
        case user(MessageTurn)
        case system(MessageTurn)
        case assistantText(String)
        case liveText(LiveTextRun, streaming: Bool)
        /// A codex Plan-mode `<proposed_plan>` block lifted out of settled
        /// prose, drawn as a plan card. (A live run's blocks are split by its
        /// `liveText` leaf, which alone reads the run's text.)
        case proposedPlan(markdown: String, streaming: Bool)
        case reasoning(String)
        case liveReasoning(LiveTextRun, streaming: Bool)
        case tool(ToolCallVM)
        /// A `delegate_to_agent` / `resume_delegation` call, with the newest
        /// later check on its task: drawn as the agent that took it, read
        /// against the live binding as it draws (``ActivityLive``).
        case delegation(ToolCallVM, later: DelegationTaskRow?)
        case delegationStatusGroup([ToolCallVM])
        case taskGroup([ToolCallVM])
        case image(ImageData, caption: String?)
        /// A context-compaction boundary — rendered as a chrome-less divider, not
        /// a card.
        case compaction(CompactionInfo)
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
        case activityGroup(kind: ActivityGroupKind, steps: [ActivityToolStep], status: StepStatus, recoveredKeys: Set<String>)
        /// One plain tool call as an activity row. `recovered`: it failed and a
        /// later step of the reply redid it successfully.
        case activityTool(ActivityToolStep, recovered: Bool)
        /// A Codex `/goal`: one row naming the objective and its status, which
        /// opens onto the run's own steps (`GoalRunRow`).
        case goal(ActivityGoalStep)
        /// One task of a background-task lane, its polls folded together;
        /// `launch`: the command that started it, when that is in the reply.
        case backgroundTask(BackgroundTask.Row, launch: BackgroundLaunch?)
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
        /// The reply's steps, for a summary re-read at draw time against
        /// what the connection knows — only when it delegated anything.
        var steps: [ActivityStep] = []
        var hasDelegations = false
    }

    /// The gutter marker for this node — drives the icon and the state tint.
    var marker: MarkerKind {
        switch content {
        case .user: return .user
        case .system: return .system
        // The agent's words are a dot on the rail: its identity is on the
        // reply's header, and an agent glyph is a delegation's.
        case .assistantText, .liveText: return .prose
        case .reasoning, .liveReasoning: return .reasoning
        case .tool(let vm):
            switch vm.companion {
            case .delegationStatus: return .delegationChecks([vm], cancel: false)
            case .cancelDelegation: return .delegationChecks([vm], cancel: true)
            case .delegate: return .delegation(vm, later: nil)
            default: return .tool(icon: vm.icon, state: vm.state)
            }
        case .delegation(let vm, let later): return .delegation(vm, later: later)
        case .delegationStatusGroup(let polls): return .delegationChecks(polls, cancel: false)
        case .taskGroup(let ops):
            let running = ops.contains { $0.state == .running || $0.state == .inputStreaming }
            let state: ToolCallState = running ? .running : (ops.contains(where: \.isError) ? .error : .done)
            return .tool(icon: "checklist", state: state)
        case .image: return .image
        case .compaction: return .compaction
        case .footer: return .footer
        case .plan, .proposedPlan: return .plan
        case .thinking: return .thinking
        case .error: return .error
        case .unsupported: return .system
        case .replyHeader: return .assistant(agent)
        case .replyFoot: return .footer
        case .thought: return .reasoning
        case .activityGroup(_, let steps, let status, let recovered):
            return .toolGroup(error: steps.contains { $0.tool.status.isFailure && !recovered.contains($0.key) },
                              streaming: status.isLive)
        case .activityTool(let step, let recovered):
            return .tool(icon: ActivityRowStyle.icon(step.tool),
                         state: ActivityRowStyle.markerState(step.tool.status, recovered: recovered))
        case .goal(let goal):
            return .tool(icon: GoalRowStyle.icon, state: GoalRowStyle.markerState(goal))
        case .backgroundTask(let row, _):
            // A sub-agent polled like a background task reads as one.
            return .tool(icon: row.isSubagent ? "cpu" : "hourglass",
                         state: ActivityRowStyle.markerState(BackgroundTask.rowStatus(row), recovered: false))
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
    /// - Parameter forkPoints: stamp each reply's footer with its fork point —
    ///   the main transcript only (a sub-agent's viewer has nothing to fork).
    /// Where the running round's prompt sits in `turns`: the server's
    /// `in_flight_user_turn_id` when it is loaded, else the newest user turn.
    static func inFlightPromptIndex(_ turns: [MessageTurn], inFlightUserTurnId: String?) -> Int? {
        if let id = inFlightUserTurnId,
           let idx = turns.firstIndex(where: { $0.role == .user && $0.id == id }) {
            return idx
        }
        return turns.lastIndex(where: { $0.role == .user })
    }

    static func buildPersisted(turns rawTurns: [MessageTurn], pending: [MessageTurn], agent: AgentType, suppressInFlight: Bool, inFlightUserTurnId: String? = nil, liveness: ToolLiveness = .settled, forkPoints: Bool = false) -> [TimelineNode] {
        buildPersistedTier(turns: rawTurns, pending: pending, agent: agent, suppressInFlight: suppressInFlight,
                           inFlightUserTurnId: inFlightUserTurnId, liveness: liveness, forkPoints: forkPoints).nodes
    }

    /// The persisted tier, and the reply it ends with when nothing follows that
    /// reply — not a prompt, not an optimistic one — which is what a live reply
    /// the agent began on its own joins (`buildLive(joining:)`).
    struct PersistedTier {
        var nodes: [TimelineNode]
        var tail: TailReply?
        /// The thread's delegate calls and the checks on their tasks, folded
        /// in order (`DelegationTaskIndex`).
        var delegationFold = DelegationTaskFold()
    }

    /// A reply at the very end of the persisted tier.
    struct TailReply {
        /// Its id, which the transcript keeps for the two replies once the live
        /// one is handed off (`merge` takes the first turn's).
        let ownerID: String
        let parts: [RenderPart]
        /// Where its rows begin in the tier's nodes; they run to the end
        /// (header … answer, then its footer).
        let nodeStart: Int
    }

    /// - Parameter heldAhead: ids of turns this client holds ahead of the
    ///   server's copy (the out-of-turn overlay): no fork point names them.
    static func buildPersistedTier(turns rawTurns: [MessageTurn], pending: [MessageTurn], agent: AgentType, suppressInFlight: Bool, inFlightUserTurnId: String? = nil, liveness: ToolLiveness = .settled, forkPoints: Bool = false, heldAhead: Set<String> = []) -> PersistedTier {
        var nodes: [TimelineNode] = []
        var tail: TailReply?
        var fold = DelegationTaskFold()

        // Hide the persisted partial in-flight reply while the reattach live turn
        // (which carries the full reply) is in hand: drop the assistant turns that
        // follow the prompt that opened the running round. Earlier replies stay
        // untouched.
        //
        // That prompt is the server's `in_flight_user_turn_id` — the round's
        // EARLIEST prompt, which a round can run well past: a message steered in
        // mid-turn is persisted as a user turn of its own, and anchoring on the
        // newest user turn left the reply's part before it drawn twice (web
        // `getTimelineTurns`). Without it in the window — not stamped, or above
        // what is loaded — the newest user turn is still the best guess.
        let turns: [MessageTurn]
        if suppressInFlight,
           let promptIdx = Self.inFlightPromptIndex(rawTurns, inFlightUserTurnId: inFlightUserTurnId) {
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
        // The reply a tail fork would land after — none while an optimistic
        // prompt follows the persisted turns.
        let forkTail = forkPoints && pending.isEmpty ? ReplyForkPoint.threadTailIndex(turns) : nil

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
                tail = nil
                i += 1
            case .system:
                // A failed round's closing line draws as the same failure node
                // the live turn showed, so the round reads the same before and
                // after it is reconciled — and a reopened session still says
                // why the round came back empty.
                let failure = turn.turnErrorText
                if !failure.isEmpty {
                    nodes.append(TimelineNode(id: turn.id, content: .error(failure, details: nil), agent: agent))
                    tail = nil
                } else if !SystemText.of(turn).isEmpty {
                // Skip system turns with no renderable text so the rail doesn't
                // show a lone marker against an empty row.
                    nodes.append(TimelineNode(id: turn.id, content: .system(turn), agent: agent, startsGroup: true))
                    tail = nil
                }
                i += 1
            case .assistant:
                let inRound = inFlightIdx.map { i > $0 } ?? false
                let replyLiveness: ToolLiveness = inRound ? .round : liveness
                // A compaction no reply goes on after is a divider between
                // turns, not a step of the reply before it (web
                // `hoistedCompaction`).
                if Self.hoistsCompaction(turns, at: i) {
                    nodes.append(contentsOf: Self.compactionDivider(turns[i], liveness: replyLiveness, agent: agent))
                    // A divider stands between it and the reply above.
                    tail = nil
                    i += 1
                    continue
                }
                // The reply runs on through its assistant turns and the empty
                // placeholders between them (`replyEnd`).
                let j = Self.replyEnd(turns, from: i)
                let merged = merge(turns[i..<j].filter { $0.role == .assistant })
                // A reply in the running round is still being written (a reader
                // with no stream of its own); every other one is a record.
                let parts = MessageRender.adaptTurn(merged, liveness: replyLiveness)
                tail = TailReply(ownerID: merged.id, parts: parts, nodeStart: nodes.count)
                nodes.append(contentsOf: replyNodes(
                    parts: parts,
                    ownerID: merged.id, completed: replyLiveness != .round,
                    durationMs: merged.durationMs, agent: agent,
                    onSteps: { fold.add($0) }))
                var footer = TimelineNode(id: "\(merged.id)#footer",
                                          content: .footer(merged, questionID: lastUserID), agent: agent)
                if forkPoints {
                    let last = turns[j - 1]
                    footer.forkPoint = ReplyForkPoint(turnID: last.id, isThreadTail: forkTail == j - 1,
                                                      hasText: ReplyForkPoint.hasForkableText(last),
                                                      heldAhead: heldAhead.contains(last.id))
                }
                nodes.append(footer)
                i = j
            }
        }

        // Optimistic user turns (sent, not yet reconciled into `turns`).
        for turn in pending {
            nodes.append(TimelineNode(id: turn.id, content: .user(turn), agent: agent, startsGroup: true))
            tail = nil
        }

        return PersistedTier(nodes: nodes, tail: tail, delegationFold: fold)
    }

    /// Build the **live** node tier — the in-flight reply. Cheap (O(segments); text
    /// nodes wrap the `LiveTextRun` reference, copying no prose), so the caller
    /// rebuilds it fresh on every pass while the persisted tier stays memoized. That
    /// freshness is required for correctness, not just latency: live tool cards,
    /// gutter markers, and plan statuses mutate their `LiveToolCall`/`LiveTurn` in
    /// place and render from a value snapshot with no observing leaf, so a stale
    /// live tier would freeze them at their first-rendered state.
    /// - Parameter replyOpen: whether the live reply is unfolded — while it
    ///   is, its closing prose stays on the rail (what will turn out to be the
    ///   answer is not known yet); folded, the trailing prose is the answer and
    ///   stays in view.
    /// - Parameter joining: the reply the persisted tier ends with, when the
    ///   live one follows it with no prompt between — a turn the agent began
    ///   on its own. The two are drawn as ONE reply, as the transcript holds
    ///   them once the turn is handed off (web `mergeConsecutiveAssistantTurns`,
    ///   live included; Android `joinLive`): under the earlier reply's id, its
    ///   parts then the live ones, so its answer is the trailing run of answer
    ///   parts — the earlier answer and the new words together while the agent
    ///   only speaks, the new words alone once it takes a step — and both
    ///   replies' steps counted. The caller drops the tail's own rows (from
    ///   `nodeStart`), its footer included: what closes the reply now is the
    ///   live turn's end.
    static func buildLive(_ live: LiveTurn, agent: AgentType, replyOpen: Bool = true,
                          joining: TailReply? = nil) -> [TimelineNode] {
        liveNodes(live, agent: agent, replyOpen: replyOpen, joining: joining)
    }

    /// The tier with a live reply after it: the live rows appended, or — when
    /// the tier ends with a reply the live one joins — that reply's rows
    /// replaced by the joined reply. `open` answers whether a reply (by key)
    /// is unfolded; the live reply is the current one.
    static func appendingLive(_ live: LiveTurn, to tier: PersistedTier, agent: AgentType,
                              open: (String) -> Bool) -> [TimelineNode] {
        // A `/compact` with nothing else said is a divider after the reply,
        // as history will draw it (`hoistsCompaction`) — not a step of it.
        let joining = tier.tail.flatMap { isLoneCompaction(live) ? nil : $0 }
        var all = joining.map { Array(tier.nodes[..<$0.nodeStart]) } ?? tier.nodes
        all.append(contentsOf: buildLive(live, agent: agent,
                                         replyOpen: open(joining?.ownerID ?? live.id), joining: joining))
        return all
    }

    /// The live turn's first stretch (up to a steered note) is a compaction
    /// and nothing else. Short-circuits on anything longer, so a reply in
    /// full flow is not adapted twice per pass.
    private static func isLoneCompaction(_ live: LiveTurn) -> Bool {
        let segments = live.segments
        let end = segments.firstIndex { if case .steering = $0 { return true }; return false } ?? segments.count
        guard end > 0, end <= 2 else { return false }
        let parts = MessageRender.adaptLive(live, range: 0..<end)
        guard parts.count == 1, case .compaction = parts[0] else { return false }
        return true
    }

    // MARK: Live reply → nodes

    /// The plan is one of the reply's parts (`LiveSegment.plan`), drawn where
    /// the agent last revised it — not pinned above the reply — and keyed by
    /// the call the hand-off records it as, so it keeps its row then.
    private static func liveNodes(_ live: LiveTurn, agent: AgentType, replyOpen: Bool,
                                  joining: TailReply?) -> [TimelineNode] {
        var out: [TimelineNode] = []
        // A message the user steered into the turn ends the reply so far and
        // starts the reply to it (web `buildStreamingTurnsFromLiveMessage`):
        // each stretch between steers is a reply of its own, the message a
        // user bubble between them.
        let segments = live.segments
        var start = 0
        var ownerID = joining?.ownerID ?? live.id
        // The joined reply's own parts lead the first stretch only.
        var lead = joining?.parts ?? []
        for (idx, segment) in segments.enumerated() {
            guard case .steering(let message) = segment else { continue }
            out.append(contentsOf: liveReplyNodes(
                parts: lead + MessageRender.adaptLive(live, range: start..<idx),
                ownerID: ownerID, completed: true, agent: agent))
            lead = []
            let turn = MessageTurn(id: "steer-\(message.id)", role: .user,
                                   blocks: [.text(message.text)], timestamp: message.at)
            out.append(TimelineNode(id: turn.id, content: .user(turn), agent: agent, startsGroup: true))
            start = idx + 1
            ownerID = "\(live.id)~\(message.id)"
        }
        // Nothing streamed yet (or nothing since a note was steered in): the
        // agent is working on it — under the reply's header (the one it
        // joined, if any, already on screen above), where its first words or
        // step will land, so they take the dots' place instead of the header
        // moving up as the dots go.
        let thinking = start == segments.count && live.isStreaming && live.errorMessage == nil
            ? TimelineNode(id: "\(ownerID)#thinking", content: .thinking, agent: agent) : nil
        out.append(contentsOf: liveReplyNodes(
            parts: lead + MessageRender.adaptLive(live, range: start..<segments.count),
            ownerID: ownerID, completed: !live.isStreaming, agent: agent,
            keepAnswer: live.isStreaming && replyOpen))
        if let thinking { out.append(thinking) }
        if let error = live.errorMessage {
            out.append(TimelineNode(id: "\(live.id)#error",
                                    content: .error(error, details: live.errorDetails), agent: agent))
        }
        return out
    }

    /// One stretch of the live turn as a reply — or, while a compaction is
    /// all it holds, the divider history will draw for it (`hoistsCompaction`):
    /// a `/compact` with nothing else said (yet) is no reply. Once the reply
    /// goes on, the compaction is one of its steps.
    private static func liveReplyNodes(parts: [RenderPart], ownerID: String, completed: Bool,
                                       agent: AgentType, keepAnswer: Bool = false) -> [TimelineNode] {
        if parts.count == 1, case .compaction(let info) = parts[0] {
            return [compactionNode(info, id: "\(ownerID)#0", agent: agent)]
        }
        return replyNodes(parts: parts, ownerID: ownerID, completed: completed, durationMs: nil,
                          agent: agent, keepAnswer: keepAnswer)
    }

    // MARK: Reply → activity nodes

    /// One reply as the activity timeline draws it (web `CompletedTurnContent`):
    /// its header capsule, its process rows, the fold-back foot, then the
    /// trailing answer, which stays in view when the reply folds. Every node is
    /// tagged with the reply and its role; WHICH of them show is decided after
    /// the memoized build, by `ReplyFolding.apply`.
    private static func replyNodes(parts: [RenderPart], ownerID: String, completed: Bool,
                                   durationMs: Int?, agent: AgentType,
                                   keepAnswer: Bool = false,
                                   onSteps: (([ActivityStep]) -> Void)? = nil) -> [TimelineNode] {
        // `keepAnswer`: an unfolded reply still being written keeps its closing
        // prose on the rail (web `proseOnRail`). Whether the reply can FOLD is
        // decided on the real split either way — a text-only live reply has no
        // process to fold.
        let model = BuildActivity.build(parts, isStreaming: !completed, keepAnswer: keepAnswer)
        let split = BuildActivity.splitTrailingAnswer(parts)
        let bodyCount = split.body.count
        let answerStart = parts.count - model.answer.count
        // Nothing but an empty answer — or a settled reply that did no steps
        // and has no time to report — gets no header, just what there is. (The
        // web keeps a bare `Reply` capsule there so the slot never blinks while
        // a reply settles; on a phone a capsule saying nothing is a wasted row.
        // A live reply keeps its `Working` header for that continuity.)
        if completed, bodyCount == 0,
           !BuildActivity.hasVisibleAnswer(split.trailing) || (durationMs ?? 0) <= 0 {
            var headerless: [TimelineNode] = []
            for (idx, part) in parts.enumerated() {
                for var n in nodes(for: part, ownerID: ownerID, index: idx, agent: agent) {
                    n.reply = .init(key: ownerID, role: .always)
                    headerless.append(n)
                }
            }
            return headerless
        }
        // Folding trades the process away to keep the answer, so a reply with no
        // answer left (stopped mid-call, or whose last card IS the answer)
        // settles un-foldable. A live reply is exempt from the answer half: its
        // closing prose has not been written yet.
        let foldable = bodyCount > 0 && (!completed || BuildActivity.hasVisibleAnswer(split.trailing))
        onSteps?(model.steps)
        let delegates = ActivitySummarize.flatten(model.steps).contains { step in
            guard let tool = step.toolStep else { return false }
            return tool.tool.kind == .delegation || tool.tool.kind == .delegationResume
        }
        let header = TimelineNode.ReplyHeader(
            replyKey: ownerID, summary: model.summary, completed: completed,
            foldable: foldable, hasSteps: !model.items.isEmpty, durationMs: durationMs,
            steps: delegates ? model.steps : [], hasDelegations: delegates)
        func member(_ node: TimelineNode, _ role: TimelineNode.ReplyMembership.Role) -> TimelineNode {
            var tagged = node
            tagged.reply = .init(key: ownerID, role: role)
            return tagged
        }

        var out: [TimelineNode] = [member(
            TimelineNode(id: "\(ownerID)#header", content: .replyHeader(header), agent: agent), .header)]
        let recovered = model.summary.recoveredKeys
        for item in model.items {
            let outlives = canOutliveReply(item)
            for node in nodes(for: item, ownerID: ownerID, agent: agent, recovered: recovered) {
                out.append(member(node, role(of: node, outlives: outlives)))
            }
        }
        if foldable {
            out.append(member(TimelineNode(id: "\(ownerID)#foot", content: .replyFoot(header), agent: agent), .foot))
        }
        for (offset, part) in model.answer.enumerated() {
            for node in nodes(for: part, ownerID: ownerID, index: answerStart + offset, agent: agent) {
                out.append(member(node, .always))
            }
        }
        return out
    }

    /// Where a process row goes while its reply is folded. A background-task
    /// lane can outlive its reply, but row by row: only a task whose newest
    /// poll is still in flight stays in view (web `BackgroundTaskRows` under
    /// `pinnedOnly`).
    private static func role(of node: TimelineNode, outlives: Bool) -> TimelineNode.ReplyMembership.Role {
        if case .backgroundTask(let row, _) = node.content {
            return BackgroundTask.staysInView(row) ? .pinned : .body
        }
        return outlives ? .pinned : .body
    }

    /// Rows that can outlive their reply — kept in view when it folds, while
    /// what they stand for is still running. That is the CHILD's lifecycle,
    /// not the launching call's: an async delegation settles its call with a
    /// "running" acknowledgement the moment the child starts, and so does a
    /// Grok background spawn — the same reading their cards use.
    private static func canOutliveReply(_ item: ActivityItem) -> Bool {
        guard case .step(let step) = item else { return false }
        switch step {
        case .delegationPolls(_, _, let status):
            return status.isLive
        case .backgroundTasks:
            // Task by task — see `role(of:outlives:)`.
            return true
        case .tool(let tool):
            let vm = tool.call
            switch tool.tool.kind {
            case .delegation, .delegationResume:
                // A refused resume revived nothing — no child of its own to
                // outlive the reply, whatever status its report names (web:
                // `DelegationResumeRow` pins nothing for one).
                if tool.tool.kind == .delegationResume, DelegationModel.isRefusedResume(vm) { return false }
                // The broker patches the call's meta with the child's terminal
                // status once it finishes — authoritative over everything else.
                let meta = DelegationModel.parseDelegationMeta(vm.meta)
                if let meta, meta.status == .ok || meta.status == .err { return false }
                if tool.tool.status.isLive { return true }
                if let later = tool.laterPolls,
                   let task = DelegationModel.buildTaskRows(later)
                       .first(where: { $0.taskId == ActivitySummarize.delegationTaskId(tool) }) {
                    // `.checked` is a poll that RETURNED while the task was still
                    // running — the newest word on the child, and it says running.
                    switch task.badge.status {
                    case .running, .starting, .checked, .waiting: return true
                    case .ok, .err: return false
                    }
                }
                let hasError = vm.isError || vm.state == .error
                let status = DelegationModel.resolveStatus(
                    parsedMeta: meta,
                    toolOutput: DelegationModel.parseToolOutput(vm.output, forceError: vm.isError),
                    state: vm.state, hasError: hasError)
                return status == .starting || status == .running || status == .waiting
            case .agent:
                return tool.tool.status.isLive || (vm.isLive && GrokSubagent.isBackgroundLaunchAck(vm.output))
            case .delegationStatus:
                return tool.tool.status.isLive
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func nodes(for item: ActivityItem, ownerID: String, agent: AgentType,
                              recovered: Set<String>) -> [TimelineNode] {
        switch item {
        case .group(_, let kind, let steps, let status):
            // Keyed as its first call's own row (Android e6af28a): while the
            // reply is written that call stands alone until the next one of
            // its kind joins it, and the row has to stay the same row as it
            // becomes their group — a new key would drop the card and draw
            // another in its place. The key also holds while the run grows and
            // across the live → history hand-over.
            let gid = steps.first.map { "tool-\($0.call.id)" } ?? "\(ownerID)#group"
            return [TimelineNode(id: gid, content: .activityGroup(
                kind: kind, steps: steps, status: status,
                recoveredKeys: recovered.intersection(steps.map(\.key))), agent: agent)]
        case .step(.backgroundTasks(let tasks)):
            // A row per task.
            return backgroundTaskNodes(stepKey: tasks.key, rows: tasks.rows, launches: tasks.launches, agent: agent)
        case .step(let step):
            return [node(for: step, ownerID: ownerID, agent: agent, recovered: recovered)]
        }
    }

    /// A background-task lane's rows, each keyed `<step key>:<row key>` — the
    /// lane's first poll and the task — so a row keeps its identity while the
    /// lane grows and across the live → history hand-over.
    private static func backgroundTaskNodes(stepKey: String, rows: [BackgroundTask.Row],
                                            launches: [String: BackgroundLaunch],
                                            agent: AgentType) -> [TimelineNode] {
        rows.map { row in
            TimelineNode(id: "\(stepKey):\(row.key)",
                         content: .backgroundTask(row, launch: row.taskId.flatMap { launches[$0] }),
                         agent: agent)
        }
    }

    /// One step's node. (A background-task lane is several — `nodes(for:)`.)
    private static func node(for step: ActivityStep, ownerID: String, agent: AgentType,
                             recovered: Set<String>) -> TimelineNode {
        let base = "\(ownerID)#\(BuildActivity.rowIdentity(step.key))"
        switch step {
        case .tool(let tool) where tool.tool.kind == .goal:
            // A goal call outside any run draws as the goal row too.
            return TimelineNode(id: "tool-\(tool.call.id)", content: .goal(BuildActivity.loneGoalStep(tool)),
                                agent: agent)
        case .tool(let tool):
            let content: TimelineNode.Content
            if ActivityRowStyle.usesRow(tool) {
                content = .activityTool(tool, recovered: recovered.contains(tool.key))
            } else if DelegationModel.drawsCard(tool.call, kind: tool.tool.kind) {
                content = .delegation(tool.call, later: DelegationModel.latestTaskRow(
                    tool.laterPolls, taskId: ActivitySummarize.delegationTaskId(tool)))
            } else {
                content = .tool(tool.call)
            }
            return TimelineNode(id: "tool-\(tool.call.id)", content: content, agent: agent)
        case .thought(_, let text, let streaming):
            if case .live(let run, _) = text {
                return TimelineNode(id: "k-\(run.id)", content: .thought(text, streaming: streaming), agent: agent)
            }
            return TimelineNode(id: base, content: .thought(text, streaming: streaming), agent: agent)
        case .note(_, .text(.settled(let s))):
            return TimelineNode(id: base, content: .assistantText(s), agent: agent)
        case .note(_, .text(.live(let run, let streaming))):
            return TimelineNode(id: "t-\(run.id)", content: .liveText(run, streaming: streaming), agent: agent)
        case .note(_, .proposedPlan(let markdown, let streaming)):
            return TimelineNode(id: base, content: .proposedPlan(markdown: markdown, streaming: streaming), agent: agent)
        case .note(_, .turnError(let message)):
            return TimelineNode(id: base, content: .error(message, details: nil), agent: agent)
        case .image(_, let image, let caption):
            return TimelineNode(id: base, content: .image(image, caption: caption), agent: agent)
        case .plan(_, let id, let entries, let streaming):
            return planNode(id: id, entries: entries, streaming: streaming, agent: agent)
        case .delegationPolls(_, let polls, _):
            let gid = polls.first.map { "delegstatus-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .delegationStatusGroup(polls), agent: agent)
        case .backgroundTasks(let tasks):
            // Never reached (`nodes(for:)` draws a row per task); the lane's
            // first task stands for it.
            let first = backgroundTaskNodes(stepKey: tasks.key, rows: tasks.rows,
                                            launches: tasks.launches, agent: agent).first
            return first ?? TimelineNode(id: base, content: .unsupported("background-task-group"), agent: agent)
        case .taskList(_, let ops):
            let gid = ops.first.map { "taskgroup-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .taskGroup(ops), agent: agent)
        case .compaction(_, let info):
            return TimelineNode(id: base, content: .compaction(info), agent: agent)
        case .unsupported(_, let type):
            return TimelineNode(id: base, content: .unsupported(type), agent: agent)
        case .goal(let goal):
            // Keyed by the opening call's id, which the live and the persisted
            // run share — so the row (and whether it is open) survives the
            // hand-over.
            return TimelineNode(id: "goal-\(goal.run.start.id)", content: .goal(goal), agent: agent)
        }
    }

    /// The thread's latest goal (its opening call's id) among `nodes` — the
    /// one the session's goal controls act on. Read from the nodes BEFORE
    /// folding: a folded reply's goal is still the session's goal.
    static func latestGoalID(_ nodes: [TimelineNode]) -> String? {
        for node in nodes.reversed() {
            if case .goal(let goal) = node.content { return goal.run.start.id }
        }
        return nil
    }

    /// A goal run's own steps as rail nodes, for its row to draw under its
    /// header (the web's nested activity timeline): the run's items mapped as
    /// a reply's are, its rail ending at its first and last node.
    static func goalBodyNodes(_ goal: ActivityGoalStep, agent: AgentType) -> [TimelineNode] {
        let recovered = goal.model.summary.recoveredKeys
        var nodes = goal.model.items.flatMap {
            Self.nodes(for: $0, ownerID: goal.key, agent: agent, recovered: recovered)
        }
        if !nodes.isEmpty {
            nodes[0].connectTop = false
            nodes[nodes.count - 1].connectBottom = false
        }
        return nodes
    }

    // MARK: Part → node

    /// A plan's node, keyed like the call it is recorded as (`tool-<id>`):
    /// the live plan's id is the one the hand-off writes its `TodoWrite` call
    /// with (`LiveTurn.planCallID`), so the row — and whether the reader
    /// collapsed its card — survives the turn ending; and a live call the
    /// persisted path finds to be a plan (a plan-like name, a checklist in
    /// its input) keeps the row it had as a call.
    private static func planNode(id: String, entries: [PlanEntry], streaming: Bool,
                                 agent: AgentType) -> TimelineNode {
        TimelineNode(id: "tool-\(id)", content: .plan(entries, streaming: streaming), agent: agent)
    }

    /// Map one `RenderPart` to its node(s): one, except a background-task lane
    /// (a row per task). IDs are chosen so a tool that is `running`
    /// during streaming keeps the SAME `List` identity once the reply finalizes
    /// (both paths key tools by their ACP tool id) — its card's expand state and
    /// marker survive the live→persisted handoff instead of flashing. Text /
    /// reasoning live runs key by the segment id (`t-`/`k-`), matching
    /// `LiveSegment.id`; finalized prose keys by its part index.
    private static func nodes(for part: RenderPart, ownerID: String, index: Int, agent: AgentType) -> [TimelineNode] {
        let base = "\(ownerID)#\(index)"
        switch part {
        case .text(let s):
            return [TimelineNode(id: base, content: .assistantText(s), agent: agent)]
        case .reasoning(let t):
            return [TimelineNode(id: base, content: .reasoning(t), agent: agent)]
        case .liveText(let run, let streaming):
            return [TimelineNode(id: "t-\(run.id)", content: .liveText(run, streaming: streaming), agent: agent)]
        case .liveReasoning(let run, let streaming):
            return [TimelineNode(id: "k-\(run.id)", content: .liveReasoning(run, streaming: streaming), agent: agent)]
        case .tool(let vm):
            let content: TimelineNode.Content = DelegationModel.drawsCard(vm, kind: DescribeToolCall.kind(vm))
                ? .delegation(vm, later: nil) : .tool(vm)
            return [TimelineNode(id: "tool-\(vm.id)", content: content, agent: agent)]
        case .delegationStatusGroup(let polls):
            let gid = polls.first.map { "delegstatus-\($0.id)" } ?? base
            return [TimelineNode(id: gid, content: .delegationStatusGroup(polls), agent: agent)]
        case .backgroundTaskGroup(let polls):
            // Process, so never part of an answer; drawn like its step all the
            // same, without the launches (those are read off the reply's steps).
            guard let first = polls.first else { return [] }
            return backgroundTaskNodes(stepKey: "bg:\(first.id)", rows: BackgroundTask.buildRows(polls),
                                       launches: [:], agent: agent)
        case .taskGroup(let ops):
            let gid = ops.first.map { "taskgroup-\($0.id)" } ?? base
            return [TimelineNode(id: gid, content: .taskGroup(ops), agent: agent)]
        case .plan(let id, let entries, let streaming):
            return [planNode(id: id, entries: entries, streaming: streaming, agent: agent)]
        case .image(let img, let cap):
            return [TimelineNode(id: base, content: .image(img, caption: cap), agent: agent)]
        case .compaction(let info):
            return [TimelineNode(id: base, content: .compaction(info), agent: agent)]
        case .proposedPlan(let markdown, let streaming):
            return [TimelineNode(id: base, content: .proposedPlan(markdown: markdown, streaming: streaming), agent: agent)]
        case .turnError(let message):
            return [TimelineNode(id: base, content: .error(message, details: nil), agent: agent)]
        case .unknown(let type):
            return [TimelineNode(id: base, content: .unsupported(type), agent: agent)]
        case .goalRun(let run):
            // A run is process, never the answer, so the reply builder draws it
            // through its step; this keeps a stray one drawn the same way.
            return [TimelineNode(id: "goal-\(run.start.id)", content: .goal(BuildActivity.goalStep(run)),
                                 agent: agent)]
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
