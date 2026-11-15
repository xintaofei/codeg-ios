import Foundation

/// The visual lifecycle of a tool call. Persisted calls are `.done`/`.error`
/// (paired with their result) or `.running` (no result block); live calls move
/// through `.running` → `.done`/`.error` as ACP updates arrive.
enum ToolCallState {
    case inputStreaming
    case running
    case done
    case error
}

/// What a transcript is allowed to treat as evidence that one of its tool calls
/// is still working. A transcript is a *record*, so the default is "nothing" —
/// see ``MessageRender/toolState(paired:isError:status:liveness:)``.
enum ToolLiveness: Hashable {
    /// A record of something that already happened. Only a terminal `status` is
    /// read; nothing spins.
    case settled
    /// This transcript is being re-read while its session runs (the sub-agent
    /// viewer polls a grok child's file on a timer). Grok pairs every call with
    /// a placeholder result and backfills it, so its unfinished calls arrive
    /// already matched and the call's own `status` is the only honest signal —
    /// which this makes trustworthy. Silence still isn't: an unpaired call with
    /// no status stays settled, exactly as in a record.
    case status
    /// The server says the round these turns belong to is running right now
    /// (`in_flight_user_turn_id`). That vouches for an unfinished call whether
    /// or not it carries a status — it is what a cross-client reader has
    /// instead of a live stream.
    case round
}

/// Coarse category a tool falls into — drives the icon and the group summary
/// ("Read 3 files · Edited 2 files"). Mirrors the codeg client's tool-kind
/// buckets.
enum ToolKindBucket {
    case read, edit, search, execute, web, todo, task, taskMgmt, other
    /// codex's unified-exec session tools (`wait` / `write_stdin`). Kept out of
    /// `.execute`: their arguments carry a session id, not a command, so the
    /// Terminal card's title derivation came up empty and every one of them
    /// rendered as a bare "Bash" over a parameter dump.
    case session
    /// codex code mode's undecomposable script (`codex_script`) — JS source, not
    /// a shell command.
    case script
}

/// A unified, view-ready model for one tool call. Both the persisted path
/// (`tool_use` + `tool_result` paired) and the live path (`LiveToolCall`) adapt
/// into this, so the card UI is shared. Derived fields (title, icon, bucket,
/// diff) are computed once at construction.
struct ToolCallVM: Identifiable {
    let id: String
    let rawName: String
    let kind: String
    let state: ToolCallState
    let input: String?
    let output: String?
    /// ACP "rendered content" — for an edit this is a unified diff. Live only.
    let content: String?
    let isError: Bool
    /// ACP extensibility metadata (`meta`). For `delegate_to_agent` it carries
    /// `codeg.delegation = { status, error_code?, text_preview?, duration_ms? }`,
    /// the authoritative terminal status the delegate card prefers over the ack.
    let meta: AnyJSON?
    /// This call's sub-agent transcript, when it launched one. Live only — the
    /// backend never persists sub-agent blocks, so the persisted path always
    /// leaves this empty. See ``SubAgentRun``.
    let transcript: [SubAgentRun]
    /// What the sub-agent's own transcript reported, off the paired
    /// `tool_result`. Persisted only; the live path carries the same facts on
    /// `meta` instead.
    let agentStats: AgentExecutionStats?
    /// The process exit code the transcript kept as a field
    /// (`tool_result.exit_code`); nil when unknown. Persisted calls only.
    let exitCode: Int?
    /// The tool's name as the web adapter stores it: a persisted call's own
    /// name, or — for a live call, whose ACP update carries only a human title
    /// — the name `ToolNameNormalizer.inferLiveToolName` reads off its title,
    /// kind, input and `_meta`. What the activity timeline classifies on;
    /// `rawName` stays as it was for the older cards.
    let toolName: String
    /// This call is being rendered from a turn whose wire data is still
    /// arriving. Only a background sub-agent launch reads it (see
    /// ``SubAgentSection``): such a launcher settles at its ack while the child
    /// works on, so the launcher's own state can't say whether the child is
    /// still going — but the reply it settled inside can, and unlike the ack
    /// text that claim expires on its own.
    let isLive: Bool

    // Precomputed derived
    let displayTitle: String
    let bucket: ToolKindBucket
    /// Non-nil for a codeg-mcp companion tool (delegate / status / cancel / ask),
    /// which renders through its own card instead of `ToolCallCard`.
    let companion: CompanionKind?
    let icon: String
    let diffFiles: [DiffFile]?
    /// The background shell this command left running, when its own script
    /// echoed the id. One session is polled by any number of later `wait` cards,
    /// and the ones this echo comes with are exactly the ones the history parser
    /// could NOT title by a command — so naming the session here is what ties
    /// those "Wait cell 17983" cards back to the command that started it.
    let announcedSessionId: String?
    /// Set when this call was identified as a codex command action, i.e. its
    /// name, arguments and bucket were all recovered — from a live call's title
    /// (`CodexCommandAction`), or from the command line a saved one ran
    /// (`CodexShellAction`).
    let commandAction: CodexCommandAction.Resolved?
    /// The plan document a plan-*mode* call carries (Claude's `ExitPlanMode`
    /// `{plan: "…"}`), drawn as a plan card rather than as a raw argument;
    /// nil for every other call. Read only for plan-mode calls, so the live
    /// tier's per-pass rebuild parses nothing more for the rest.
    let planDocument: String?

    init(id: String, rawName: String, kind: String, state: ToolCallState,
         input: String?, output: String?, content: String?, isError: Bool,
         meta: AnyJSON? = nil, transcript: [SubAgentRun] = [],
         agentStats: AgentExecutionStats? = nil, isLive: Bool = false, exitCode: Int? = nil,
         toolName: String? = nil) {
        // A codex-acp command action (`createCommandActionEvent`) has no tool
        // name and NO input — only a human title, which arrives here as
        // `rawName`. Its identity, its query and its path all have to be read
        // back out of that title; the synthesized input below is what the
        // desktop's runtime writes onto the tool-use block, so every derivation
        // downstream sees an ordinary Read/Grep/Glob call.
        //
        // Gated on there being no input at all, which is the shape codex sends:
        // a tool carrying real arguments must never be re-identified by its
        // title. (Same gate as the web's `inferLiveToolName`.)
        let action = (input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? CodexCommandAction.resolve(title: rawName)
            : nil
        // Grok's plan-mode tools carry their authoritative identity in
        // `_meta["x.ai/tool"].kind`, while the `title` we're handed as `rawName`
        // MUTATES across the lifecycle (`enter_plan_mode` → "Plan: Enter" → "Plan
        // mode entered"). Resolve them to the canonical name up front so the live
        // stream lands on the same identity the persisted path reads from
        // `x.ai/tool.name` — and so the card's title stops changing mid-stream.
        let planName = ToolDerive.grokPlanModeName(meta)
        // The saved copy of such a command keeps only `exec_command` and the
        // command line: read the line as codex did, so the reply reads back with
        // the steps it streamed ("Read 2 files", not "Ran 2 commands"). Saved
        // calls only — a live call (`toolName` given) announced its own identity.
        let shellAction = planName == nil && action == nil && toolName == nil && CodexShellAction.isShellName(rawName)
            ? CodexShellAction.commandOf(input: input, parsed: ToolDerive.parseJSON(input))
                .flatMap(CodexShellAction.resolve)
            : nil
        let recovered = action ?? shellAction
        let resolvedName = planName ?? recovered?.name ?? rawName
        // The command line is all the saved call sent; the target it names is
        // the input the live action's card was drawn from.
        let resolvedInput = shellAction?.input ?? input ?? action?.input
        // A saved search that matched nothing is rg's exit 1, which codex calls
        // a failure. As a command the exit reader settled it; as the search it
        // now is, it settles the way the live one does (`GrepNoMatch`): done,
        // with the empty result the search card reads as "No matches".
        let savedNoMatch = shellAction?.isGrepLike == true && (isError || state == .error)
            && CodexShellAction.isNoMatchResult(output: output, exitCode: exitCode)
        let effectiveToolName = toolName ?? shellAction?.name ?? rawName
        let effectiveOutput = savedNoMatch ? "" : output
        self.id = id
        self.rawName = resolvedName
        self.kind = kind
        self.state = savedNoMatch ? .done : state
        self.input = resolvedInput
        self.output = effectiveOutput
        self.content = content
        // `state == .error` and `isError` must agree: the state drives THIS card,
        // but `isError` is what everything above it reads — the group's "N failed"
        // badge, the group / delegation-poll / checklist rail markers, and the gate
        // that keeps a failed task op out of the successful checklist. A failure
        // the tool's own `status` declared has no result block to carry the flag,
        // so it is stamped here rather than at each of those sites.
        self.isError = !savedNoMatch && (isError || state == .error)
        self.meta = meta
        self.transcript = transcript
        self.agentStats = agentStats
        self.exitCode = exitCode
        self.toolName = effectiveToolName
        self.isLive = isLive
        self.commandAction = recovered

        let parsed = ToolDerive.parseJSON(resolvedInput)
        // A command action's bucket comes from its resolved name ALONE, never
        // the ACP `kind`: codex labels `List files in 'src'` as kind "read",
        // which would route it to the file-read body and dump the raw envelope.
        // (The web classifies on the name only; iOS's kind-first rule is an
        // addition, and it has to yield here.)
        let b = recovered.map { ToolDerive.bucket(name: $0.name, kind: "") }
            ?? ToolDerive.bucket(name: resolvedName, kind: kind)
        let comp = CompanionDetect.kind(name: resolvedName, input: resolvedInput, parsed: parsed)
            ?? CompanionDetect.delegateByToolName(effectiveToolName, input: resolvedInput, meta: meta)
        self.bucket = b
        self.companion = comp
        self.displayTitle = ToolDerive.title(name: resolvedName, bucket: b, input: resolvedInput, parsed: parsed)
        self.icon = comp.map(ToolDerive.companionIcon)
            ?? ToolDerive.icon(bucket: b, name: resolvedName, input: resolvedInput)
        self.diffFiles = ToolDerive.diff(bucket: b, input: resolvedInput, output: effectiveOutput,
                                         content: content, parsed: parsed)
        self.announcedSessionId = ToolDerive.announcedSession(name: resolvedName, output: effectiveOutput)
        // By either name: a live call's wire name is a human title, and the
        // name inferred from its kind and input is the one that says plan mode.
        let planModeCall = ToolDerive.isPlanModeName(resolvedName) || ToolDerive.isPlanModeName(effectiveToolName)
        self.planDocument = planModeCall ? PlanParse.planMarkdown(resolvedInput) : nil
    }

    /// Grok's live sub-agent ticker, when this call launched one and a tick has
    /// arrived. The only live signal of a grok child's work — it forwards none
    /// of the child's chunks or tool calls.
    var grokProgress: GrokSubagent.Progress? { GrokSubagent.progress(meta: meta) }

    /// The child's own session, when the sub-agent ran as one — the entry point
    /// to what it actually did. Present both live and in history.
    var childSession: GrokSubagent.ChildSession? {
        GrokSubagent.childSession(meta: meta, stats: agentStats)
    }

    /// The pattern a search-shaped call looked for, highlighted in its results.
    var searchQuery: String? {
        guard bucket == .search else { return nil }
        let args = ToolDerive.effectiveArgs(ToolDerive.parseJSON(input))
        for key in ["pattern", "query", "regex", "q"] {
            if let v = args?[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// The text a search-shaped call should render as grouped results, or nil to
    /// fall through to the generic output renderer. Mirrors the web's
    /// `searchOutput` memo, including its error-channel special case.
    var searchResultText: String? {
        guard bucket == .search else { return nil }
        if isError {
            // codex derives the tool status from the exit code, so an rg/grep
            // "no matches" (exit 1, no output) arrives as a FAILED call and
            // lands on the error channel. Recognise exactly that shape as an
            // empty result instead of a red envelope dump. Scoped to grep-likes:
            // exit 1 means "nothing selected" only for those — for the list
            // commands that classify as `glob` it is a genuine failure, and a
            // successful empty listing already arrives with exit 0. A real grep
            // failure (exit ≥ 2, or any stderr text) keeps the error rendering.
            guard commandAction?.isGrepLike ?? (ToolDerive.isGrepName(rawName)) else { return nil }
            guard let envelope = CodexCommandEnvelope.parse(output), envelope.exitCode == 1,
                  envelope.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ""
        }
        guard let output else { return nil }
        // The STRICT envelope parse (both `formatted_output` and `exit_code`):
        // the looser `ToolOutputFormat.commandOutput` would treat a legitimate
        // JSON search result as an envelope and flatten it to empty text.
        return CodexCommandEnvelope.parse(output)?.output ?? output
    }

    var trimmedOutput: String { (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasOutput: Bool { !trimmedOutput.isEmpty }
    /// Bash/shell output renders in a terminal-ish code block. Session polls are
    /// included: what a `wait` returns IS the background shell's stdout, wrapped
    /// in the same `{formatted_output, exit_code}` envelope a command result uses.
    var isCommand: Bool { bucket == .execute || bucket == .session }
    /// A plan-*mode* transition (Claude's `EnterPlanMode`/`ExitPlanMode`, Grok's
    /// `enter_plan_mode`/`exit_plan_mode`, Cline's `switch_mode`). A mode signal,
    /// not a work tool, so it renders standalone instead of folding into a group.
    var isPlanMode: Bool { ToolDerive.isPlanModeName(rawName) }
}

/// One ordered piece of a rendered assistant turn. The persisted and live
/// adapters both produce this list; `TranscriptTimeline` maps each part to a
/// timeline node and `NodeBody` renders it.
enum RenderPart {
    case text(String)                                   // finalized prose → block markdown
    /// A codex Plan-mode `<proposed_plan>` block lifted out of settled prose
    /// (`ProposedPlan.extract`). `streaming`: the block is still open in a
    /// reply that is still being written. Live prose is split by its leaf view
    /// instead (see `LiveTextNode`), so it never reaches here.
    case proposedPlan(markdown: String, streaming: Bool)
    case reasoning(text: String)                        // finalized reasoning
    case liveText(LiveTextRun, streaming: Bool)          // streaming prose (plain, @Bindable)
    case liveReasoning(LiveTextRun, streaming: Bool)
    case tool(ToolCallVM)
    /// A run of consecutive `get_delegation_status` polls, merged into one card.
    case delegationStatusGroup([ToolCallVM])
    /// A run of consecutive background-task polls (Claude Code's `TaskOutput`
    /// / `TaskStop`, Grok's and CodeBuddy's — `BackgroundTask.isToolCall`),
    /// drawn as one row per task.
    case backgroundTaskGroup([ToolCallVM])
    /// A run of consecutive task-management calls (`TaskCreate`/`TaskUpdate`/
    /// `TaskList`/`TaskGet`), merged into one evolving checklist card.
    case taskGroup([ToolCallVM])
    /// A plan checklist: the live turn's plan (`LiveSegment.plan`), or a
    /// persisted plan-like call that carries one (`PlanParse`) — drawn as the
    /// same card either way. `id` is the call it is recorded as: the hand-off
    /// keeps the live plan as a call of that id (`LiveTurn.planCallID`), so
    /// the row is the same one live and handed off. `streaming`: its turn is
    /// still running (the in-progress entry spins).
    case plan(id: String, entries: [PlanEntry], streaming: Bool)
    case image(ImageData, caption: String?)
    /// A context compaction (`_meta.contextCompaction`, either shape) — a
    /// conversation boundary marker, not a tool call. Rendered as a chrome-less
    /// centered divider.
    case compaction(CompactionInfo)
    /// A `turn_error` block. Normally alone in a `system` turn (drawn by the
    /// timeline builder directly); this covers one found inside a reply.
    case turnError(String)
    case unknown(type: String)
    /// A Codex `/goal` run: `create_goal`, the parts it holds, and the closing
    /// `update_goal` when there was one (`GoalRuns.group`).
    case goalRun(GoalRunPart)
}

// MARK: - Adapters

/// Adapts persisted `MessageTurn`s and live `LiveTurn`s into `[RenderPart]`.
/// Main-actor isolated: it reads the `@MainActor` live models and is only ever
/// called from a view body.
@MainActor
enum MessageRender {

    /// - Parameter liveness: what may put a spinner on one of this turn's tool
    ///   calls. `.settled` (a record) for all but two cases — see `toolState`.
    ///
    /// Plain calls stay ungrouped: the activity timeline groups them by kind
    /// itself, and takes only the delegation-poll, background-task and
    /// task-checklist lanes from here.
    static func adaptTurn(_ turn: MessageTurn, liveness: ToolLiveness = .settled) -> [RenderPart] {
        let cacheKey = TurnKey(turn: turn, liveness: liveness)
        if let cached = turnCache[cacheKey] { return cached }

        let blocks = turn.blocks
        var consumed = Set<Int>()
        var parts: [RenderPart] = []

        for (idx, block) in blocks.enumerated() where !consumed.contains(idx) {
            switch block {
            case .text(let t):
                // codex Plan mode writes its plan as a `<proposed_plan>` block in
                // the prose; it becomes a card, the prose around it stays prose.
                // Only a reply still being written in the running round can
                // have a block that is merely not closed YET.
                if let segments = ProposedPlan.extract(t, isStreaming: liveness == .round) {
                    for segment in segments {
                        switch segment {
                        case .text(let prose): parts.append(.text(prose))
                        case .plan(let markdown, let streaming):
                            parts.append(.proposedPlan(markdown: markdown, streaming: streaming))
                        }
                    }
                } else if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(.text(t))
                }
            case .thinking(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.reasoning(text: t)) }
            case .image(let img):
                parts.append(.image(img, caption: nil))
            case .imageGeneration(let prompt, let img):
                if let img { parts.append(.image(img, caption: prompt)) }
                else if let prompt, !prompt.isEmpty { parts.append(.text(prompt)) }
            case .toolUse(let toolID, let name, let inputPreview, let status, let meta):
                let resultIdx = findResult(in: blocks, after: idx, toolID: toolID, consumed: consumed)
                // A plan-like call that carries a checklist draws as the plan the
                // live stream showed (web: a `plan` part), its result ("Todos have
                // been modified") consumed with it. Only one that yields entries —
                // anything else (a read, a clear, a plan-mode document) stays a
                // call. And only one that applied: a failed write keeps its error
                // card rather than drawing a plan that never took, as a failed
                // task op stays out of the task checklist.
                if PlanParse.isPlanLikeToolName(name) {
                    let entries = PlanParse.parseTodos(inputPreview)
                    var rejected = status == .failed
                    if let r = resultIdx, case .toolResult(_, _, let e, _, _) = blocks[r] { rejected = rejected || e }
                    if !entries.isEmpty, !rejected {
                        if let r = resultIdx { consumed.insert(r) }
                        parts.append(.plan(id: toolID ?? "\(turn.id)#plan-\(idx)", entries: entries,
                                           streaming: liveness == .round))
                        continue
                    }
                }
                var output: String?
                var isErr = false
                var stats: AgentExecutionStats?
                var exitCode: Int?
                if let r = resultIdx, case .toolResult(_, let outPreview, let e, let s, let code) = blocks[r] {
                    output = outPreview; isErr = e; stats = s; exitCode = code; consumed.insert(r)
                }
                // codex's own search that failed live with nothing printed is
                // rg's exit 1 — "no matches" — and settles as a success, its
                // empty body the search card's "No matches" (web
                // `isGrepNoMatchResult`). Only a live status says `failed`: a
                // record of codex's search keeps its own rendering.
                let noMatch = resultIdx != nil && isErr && status == .failed
                    && GrepNoMatch.isCodexSearchNoMatch(toolName: name, input: inputPreview, output: output, meta: meta)
                if noMatch {
                    isErr = false
                    output = output ?? ""
                }
                let state: ToolCallState = noMatch
                    ? .done
                    : toolState(paired: resultIdx != nil, isError: isErr, status: status, liveness: liveness)
                // A compaction is a boundary marker, not a call: it renders as a
                // divider between turns, so it never becomes a `ToolCallVM` (and so
                // can't be swept into a tool group).
                if ContextCompaction.matches(meta) {
                    parts.append(.compaction(ContextCompaction.info(
                        meta: meta, output: output, running: state == .running, failed: state == .error,
                        callID: toolID)))
                    continue
                }
                parts.append(.tool(ToolCallVM(
                    id: toolID ?? "tool-\(idx)", rawName: name, kind: "", state: state,
                    input: inputPreview, output: output, content: nil, isError: isErr, meta: meta,
                    agentStats: stats, exitCode: exitCode)))
            case .toolResult(let toolID, let outPreview, let e, let stats, let exitCode):
                // Orphan result (no preceding tool_use) — show it on its own.
                parts.append(.tool(ToolCallVM(
                    id: toolID ?? "result-\(idx)", rawName: "result", kind: "", state: e ? .error : .done,
                    input: nil, output: outPreview, content: nil, isError: e, agentStats: stats,
                    exitCode: exitCode)))
            case .turnError(let message):
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(.turnError(message))
                }
            case .unknown(let type):
                parts.append(.unknown(type: type))
            }
        }

        // Goal runs after the lanes, as the web does. Only a reply in the
        // running round is still being written; an unfinished run anywhere
        // else is a goal codex left open, and settles.
        let grouped = GoalRuns.group(groupLanes(parts), isStreaming: liveness == .round)
        cacheTurn(cacheKey, grouped)
        return grouped
    }

    /// The lifecycle state of a **persisted** tool call.
    ///
    /// The governing rule is that a transcript is a *record*: a `tool_use` with
    /// no `tool_result` normally means the conversation already ended, so the
    /// call settled — missing output is not evidence of liveness (an empty result
    /// still writes a `tool_result`, and a codex code-mode script that never
    /// `text()`s its call settles with none). Treating every unpaired call as
    /// running is what left orphans from an interrupted round spinning forever.
    ///
    /// Two affirmative signals override that default, and nothing else does —
    /// `liveness` says which of them this transcript has (see ``ToolLiveness``):
    ///
    /// * `status` — the agent's own statement. Terminal values settle the card
    ///   even with no result block; `.running` is only honored when something
    ///   vouches for the transcript being current, because a transcript keeps
    ///   whatever status it was last given and an interrupted call's stale
    ///   `in_progress` would otherwise produce a spinner nothing will ever clear.
    /// * a running round (`.round`) — the server says this round is live right
    ///   now, so its unfinished calls really are working, status or not. This is
    ///   what a cross-client reader (or a viewer whose attach missed) has
    ///   instead of a live stream.
    ///
    /// A live `.running` is honored even on a PAIRED call: grok pairs every call
    /// with a placeholder result and backfills it, so one of its calls that is
    /// still working arrives already matched. A failure outranks it either way —
    /// a result that errored, or a `failed` status, is terminal.
    ///
    /// `.error` here is not only this card's own indicator: `ToolCallVM` mirrors
    /// it into `isError`, which is what the enclosing group / checklist read.
    static func toolState(paired: Bool, isError: Bool,
                          status: ToolUseStatus, liveness: ToolLiveness) -> ToolCallState {
        if paired, isError { return .error }
        if status == .failed { return .error }
        if liveness != .settled, status == .running { return .running }
        if paired { return .done }
        if status == .completed { return .done }
        // Unknown, or a `running` nothing can vouch for.
        return liveness == .round ? .running : .done
    }

    /// `range`: only these segments — one reply of a turn the user steered
    /// into (see `LiveSegment.steering`). The streaming flag still follows the
    /// turn's LAST segment.
    static func adaptLive(_ turn: LiveTurn, range: Range<Int>? = nil) -> [RenderPart] {
        var parts: [RenderPart] = []
        let segments = turn.segments
        let span = range ?? segments.indices
        // Only the *final* segment is still growing — it alone carries the
        // streaming flag (the typing caret + cache bypass). Earlier text/reasoning
        // runs are frozen the moment the agent moved on to the next segment, so
        // they render as finalized (no caret, cached). Without this, every text
        // segment showed its own blinking caret.
        let lastIndex = segments.count - 1
        let hasPlan = turn.currentPlan != nil
        for idx in span {
            let segment = segments[idx]
            let isLast = idx == lastIndex
            switch segment {
            case .steering:
                continue   // a boundary between replies, drawn by the timeline
            case .text(let run):
                parts.append(.liveText(run, streaming: turn.isStreaming && isLast))
            case .thinking(let run):
                parts.append(.liveReasoning(run, streaming: turn.isStreaming && isLast))
            case .plan(let entries):
                // Where the agent last revised it — the same place, and the same
                // row, as the turn handed off keeps it (`snapshotAsMessageTurns`).
                // Its spinner follows the turn, not the segment: text written
                // after a revision doesn't make the plan any less current.
                parts.append(.plan(id: turn.planCallID, entries: entries, streaming: turn.isStreaming))
            case .tool(let call):
                // Kimi sends each todo write twice: as this call, and as the plan
                // update the `plan` segment holds. Once that plan is in, it stands
                // for every write (web `buildStreamingTurnsFromLiveMessage`);
                // before it lands — or if it never does — the write is drawn as
                // the plan it carries, never as a generic call. Its identity is
                // the input's exact shape: the name `TodoList` is not on the wire.
                if !call.isError, let todos = PlanParse.kimiTodoWriteEntries(call.rawInput) {
                    if !hasPlan { parts.append(.plan(id: call.id, entries: todos, streaming: turn.isStreaming)) }
                    continue
                }
                let state: ToolCallState = call.isFinished ? (call.isError ? .error : .done) : .running
                // Same boundary-marker treatment as the persisted path: codex emits
                // the `Context compacting` → `Context compacted` pair on one id, so
                // the divider flips from running to settled in place.
                if ContextCompaction.matches(call.meta) {
                    parts.append(.compaction(ContextCompaction.info(
                        meta: call.meta, output: call.rawOutput, running: state == .running,
                        failed: state == .error, callID: call.id)))
                    continue
                }
                let toolName = ToolNameNormalizer.inferLiveToolName(
                    title: call.title, kind: call.kind, rawInput: call.rawInput, meta: call.meta)
                // codex's own search failing with nothing printed found nothing
                // (rg's exit 1): a success, as in the persisted path above.
                let noMatch = state == .error && call.status == "failed"
                    && GrepNoMatch.isCodexSearchNoMatch(
                        toolName: toolName, input: call.rawInput,
                        output: call.rawOutput.isEmpty ? call.content : call.rawOutput, meta: call.meta)
                parts.append(.tool(ToolCallVM(
                    id: call.id, rawName: call.title, kind: call.kind, state: noMatch ? .done : state,
                    input: call.rawInput, output: call.rawOutput, content: call.content,
                    isError: noMatch ? false : call.isError,
                    meta: call.meta, transcript: call.transcript, isLive: turn.isStreaming,
                    toolName: toolName)))
            }
        }
        // A reply the user steered away from ended there: only the stretch
        // that reaches the turn's last segment is still being written.
        return GoalRuns.group(groupLanes(parts),
                              isStreaming: turn.isStreaming && span.upperBound == segments.count)
    }

    /// Only the lanes that are rows of their own — delegation polls,
    /// background-task polls and the task checklist; plain calls are grouped
    /// by the activity model. In the web's order: delegation polls first, then
    /// background tasks out of what is left.
    static func groupLanes(_ parts: [RenderPart]) -> [RenderPart] {
        groupConsecutiveTaskOps(groupConsecutiveBackgroundTasks(groupConsecutiveDelegationStatus(parts)))
    }

    /// Wrap each run of consecutive `get_delegation_status` polls into a single
    /// `delegationStatusGroup`. Any other part — text, another call, the
    /// delegate / cancel / ask cards — breaks the run, so only genuinely consecutive polls collapse. Even a single poll is
    /// wrapped, so the merged-card "returned-running reads as a settled snapshot"
    /// resolution applies uniformly. Consecutive assistant turns are merged before
    /// adaptation (`TranscriptTimeline.merge`), so a multi-round poll sequence lands
    /// consecutively here and collapses without a separate cross-turn pass.
    ///
    /// A background-task poll is left to its own lane even when its input
    /// reads as a status check: Grok's `get_command_or_subagent_output` polls
    /// with `{task_ids, timeout_ms}`, which `CompanionDetect` takes for
    /// `get_delegation_status` by shape. A call NAMED `get_delegation_status`
    /// stays here whatever its result quotes — the web picks this lane by name
    /// (`isDelegationStatusToolName`) before the background one, and a child's
    /// report can carry a background envelope's tags as text.
    static func groupConsecutiveDelegationStatus(_ parts: [RenderPart]) -> [RenderPart] {
        var out: [RenderPart] = []
        var buffer: [ToolCallVM] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(.delegationStatusGroup(buffer))
            buffer = []
        }

        for part in parts {
            if case .tool(let vm) = part, vm.companion == .delegationStatus,
               CompanionDetect.nameKind(vm.toolName) == .delegationStatus || !BackgroundTask.isToolCall(vm) {
                buffer.append(vm)
            } else {
                flush()
                out.append(part)
            }
        }
        flush()
        return out
    }

    /// Wrap each run of consecutive background-task polls
    /// (`BackgroundTask.isToolCall`) into a single `backgroundTaskGroup`.
    /// Mirrors `groupConsecutiveDelegationStatus`: any other part breaks the
    /// run, and even a single poll is wrapped, so every poll reads through the
    /// one lane. The web also merges the groups two turns leave side by side
    /// (`mergeAdjacentBackgroundTaskGroups` / `joinMergedParts`); here the
    /// turns are merged before they are adapted, so a run spanning them is
    /// already consecutive.
    static func groupConsecutiveBackgroundTasks(_ parts: [RenderPart]) -> [RenderPart] {
        var out: [RenderPart] = []
        var buffer: [ToolCallVM] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(.backgroundTaskGroup(buffer))
            buffer = []
        }

        for part in parts {
            if case .tool(let vm) = part, BackgroundTask.isToolCall(vm) {
                buffer.append(vm)
            } else {
                flush()
                out.append(part)
            }
        }
        flush()
        return out
    }

    /// Wrap each run of consecutive *successful* task-management calls (`.taskMgmt`)
    /// into a single `taskGroup`, so a `TaskCreate ×5` burst becomes one checklist
    /// rather than five cards. Even a lone op is wrapped, so every successful task
    /// surface renders through the one checklist card. Mirrors
    /// `groupConsecutiveDelegationStatus`.
    ///
    /// A FAILED task op is deliberately left standalone (it breaks the run): a
    /// failed `TaskUpdate {status: completed}` must not render a green "completed"
    /// row as if it had applied, and a failed `TaskList`/`TaskGet` must surface its
    /// error output — both of which the standard `ToolCallCard` error path does. So
    /// the checklist only ever reflects calls that actually succeeded.
    static func groupConsecutiveTaskOps(_ parts: [RenderPart]) -> [RenderPart] {
        var out: [RenderPart] = []
        var buffer: [ToolCallVM] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(.taskGroup(buffer))
            buffer = []
        }

        for part in parts {
            if case .tool(let vm) = part, vm.bucket == .taskMgmt, vm.companion == nil, !vm.isError {
                buffer.append(vm)
            } else {
                flush()
                out.append(part)
            }
        }
        flush()
        return out
    }

    private static func findResult(in blocks: [ContentBlock], after idx: Int, toolID: String?, consumed: Set<Int>) -> Int? {
        // Prefer an exact id match anywhere later.
        if let toolID {
            for j in (idx + 1)..<blocks.count where !consumed.contains(j) {
                if case .toolResult(let rid, _, _, _, _) = blocks[j], rid == toolID { return j }
            }
        }
        // Otherwise the next unconsumed result — but stop at the next tool_use so
        // we don't steal a later call's result when ids are missing.
        for j in (idx + 1)..<blocks.count where !consumed.contains(j) {
            if case .toolUse = blocks[j] { break }
            if case .toolResult = blocks[j] { return j }
        }
        return nil
    }

    // Persisted adaptation is stable per turn *value*; memoize so a recycled List
    // row doesn't re-pair/re-parse. Live turns are never cached (they mutate).
    //
    // The key is the whole `MessageTurn`, NOT `turn.id`: this is a process-wide
    // static cache shared by every conversation, and codeg's turn ids are only
    // unique *within* a conversation (they are not global), so keying by id alone
    // let conversation B reuse conversation A's render whenever their ids collided
    // — the transcript showing "another conversation's messages". Dictionary
    // lookup compares full value equality (hash is only a bucket hint), so a
    // colliding id with different content can never produce a false hit, and a
    // turn whose content actually changed re-derives correctly.
    //
    // `liveness` rides in the key for the same reason: it changes what the very
    // same turn adapts to (a spinner vs. a settled card), so a cache keyed on
    // content alone would keep serving the running render after the round
    // completed.
    private struct TurnKey: Hashable {
        let turn: MessageTurn
        let liveness: ToolLiveness
    }
    private static var turnCache: [TurnKey: [RenderPart]] = [:]
    private static var turnOrder: [TurnKey] = []
    private static let turnLimit = 400

    private static func cacheTurn(_ key: TurnKey, _ parts: [RenderPart]) {
        turnCache[key] = parts
        turnOrder.append(key)
        if turnOrder.count > turnLimit {
            let evicted = turnOrder.removeFirst()
            turnCache.removeValue(forKey: evicted)
        }
    }
}

// MARK: - Derivation

/// Pure helpers that turn a tool name + parsed input into a human title, an
/// icon, a bucket, and (for edits) a diff. Mirrors the codeg client's
/// `deriveToolTitle` / `getToolIcon` / tool-kind classifier.
enum ToolDerive {

    static func parseJSON(_ s: String?) -> [String: Any]? {
        guard let s, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Descend into a wrapper object (`input`/`arguments`/…) when the args were
    /// nested; otherwise the object itself is the args — then fill in canonical
    /// argument names the agent spelled differently on the wire.
    ///
    /// Every card body and every derivation reads its arguments through here, so
    /// this is the one place the aliasing has to happen for Read/Write/Edit/Grep
    /// to agree on the same payload.
    static func effectiveArgs(_ parsed: [String: Any]?) -> [String: Any]? {
        guard let parsed else { return nil }
        for key in ["input", "arguments", "params", "payload"] {
            if let inner = parsed[key] as? [String: Any] { return aliased(inner) }
        }
        return aliased(parsed)
    }

    /// Wire spellings that mean the same argument as one of the canonical
    /// (snake_case) keys the cards read. OpenCode names its tool arguments in
    /// camelCase and its ACP adapter forwards them verbatim, so the LIVE stream
    /// carries `filePath` / `oldString` where the history parser has already
    /// rewritten them (`parsers/opencode.rs::normalize_tool_call`) — which is why
    /// a live Write card lost its path and a live Edit card lost its diff while
    /// the same call rendered fine after a reload. `include` → `glob` is the same
    /// one-sided rename that parser applies to OpenCode's grep filter.
    private static let argAliases: [(alias: String, canonical: String)] = [
        ("filePath", "file_path"),
        ("notebookPath", "notebook_path"),
        ("oldString", "old_string"),
        ("newString", "new_string"),
        ("newSource", "new_source"),
        ("replaceAll", "replace_all"),
        ("editMode", "edit_mode"),
        ("cellType", "cell_type"),
        ("include", "glob"),
    ]

    /// Add any missing canonical key. Only ever writes a key that is ABSENT, so
    /// it can never override what an agent actually sent — making it a no-op on
    /// every payload the Rust parsers already normalized (all history) and on
    /// every agent that speaks snake_case natively. Returns the input untouched
    /// when nothing had to be added, so the common case copies nothing.
    private static func aliased(_ args: [String: Any]) -> [String: Any] {
        var out: [String: Any]?
        for (alias, canonical) in argAliases {
            guard let value = args[alias], !(value is NSNull), args[canonical] == nil else { continue }
            if out == nil { out = args }
            out?[canonical] = value
        }
        return out ?? args
    }

    /// Pull the shell command out of a tool input. Mirrors web
    /// `commandFromUnknownValue` + `extractCommandFromUnknownInput` and handles
    /// every shape a command arrives in: a parsed object's
    /// `command`/`cmd`/`script` (string or argv array, incl. nested
    /// `input`/`arguments` wrappers), a JSON-encoded string or argv array, and —
    /// crucially — a BARE command string (Codex persists `exec_command` input as
    /// the raw command, not JSON), which otherwise fails to parse and drops the
    /// title to a generic "Bash".
    static func extractCommand(input: String?, parsed: [String: Any]?) -> String? {
        if let parsed, let c = commandFromValue(parsed) { return c }
        guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // A JSON fragment the object-parse missed (a quoted string or argv array).
        if let any = ToolJSONFormat.parseAny(raw), let c = commandFromValue(any) { return c }
        // A bare, non-JSON string is itself the command; don't echo an
        // unparseable `{…}`/`[…]` blob as if it were one.
        if raw.hasPrefix("{") || raw.hasPrefix("[") { return nil }
        return raw
    }

    private static func commandFromValue(_ value: Any) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let arr = value as? [Any] {
            let parts = arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        guard let obj = value as? [String: Any] else { return nil }
        for key in ["command", "cmd", "script", "args", "argv", "command_args"] {
            if let v = obj[key], let c = commandFromValue(v) { return c }
        }
        for key in ["input", "arguments", "params", "payload"] {
            if let v = obj[key], let c = commandFromValue(v) { return c }
        }
        return nil
    }

    static func title(name: String, bucket: ToolKindBucket, input: String?, parsed: [String: Any]?) -> String {
        let n = canonical(name)
        let args = effectiveArgs(parsed)
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = args?[k] as? String, !v.isEmpty { return v } }
            return nil
        }

        // Plan-mode transitions get a fixed human title. Grok's own titles mutate
        // as the call progresses, so deriving from the name keeps the card stable.
        if isPlanModeName(name) {
            let normalized = n.replacingOccurrences(of: "_", with: "")
            if normalized == "enterplanmode" { return "Entered plan mode" }
            if normalized == "exitplanmode" { return "Plan ready" }
            return "Switched mode"
        }

        // Execute/shell tools show the actual command. Keyed off the `bucket`
        // rather than the name: the live path identifies shells by the ACP
        // `kind` and passes an arbitrary agent-supplied title as the "name", and
        // Codex persists `exec_command` input as a BARE command string (not
        // JSON) — both previously slipped past the name switch and fell back to
        // a generic "Bash". Show the command itself (per request); description
        // and the literal label are only last resorts.
        if bucket == .execute {
            if let c = extractCommand(input: input, parsed: parsed) { return simplifyCommand(c) }
            if let d = str(["description"]) { return d }
            return "Bash"
        }

        // Task-management tools render through `TaskListCard`, but a sensible title
        // still feeds the gutter marker / accessibility.
        if bucket == .taskMgmt { return taskMgmtTitle(name: name, args: args) }

        // codex code-mode script: title from the first command the parser could
        // read out of the JS, else a plain label.
        if bucket == .script {
            if let t = CodexScriptCard.parse(input: input)?.title,
               let firstLine = simplifyCommand(t).components(separatedBy: "\n").first,
               !firstLine.isEmpty {
                return truncate(firstLine, 80)
            }
            return "Script"
        }

        // codex unified-exec session tools: title by the command whose session
        // they address (resolved by the history parser), falling back to the
        // session id. Neither carries a command of its own, so without this the
        // header read a bare "Bash" / the raw tool name.
        if bucket == .session {
            guard let call = ShellSessionCall.parse(input: input) else { return display(name) }
            if !call.chars.isEmpty { return "Stdin \(ShellSessionFormat.describeStdin(call.chars))" }
            let verb = (codexBuiltin(name) == ShellSessionCall.waitName && call.terminate)
                ? "Terminate" : "Wait"
            if let command = call.command,
               let firstLine = simplifyCommand(command).components(separatedBy: "\n").first,
               !firstLine.isEmpty {
                return truncate("\(verb) \(firstLine)", 80)
            }
            if let id = call.sessionId { return "\(verb) cell \(id)" }
            return verb
        }

        switch n {
        case "read", "read_file", "readfile", "cat", "view":
            if let p = str(["file_path", "path", "filename", "file", "target_file"]) { return "Read \(PathFormat.short(p))" }
            return display(name)
        case "edit", "str_replace", "str_replace_editor", "str_replace_based_edit_tool",
             "apply_patch", "applypatch", "patch", "multiedit", "edit_file":
            if let count = editFileCount(args: args), count > 1 { return "Edit (\(count) files)" }
            if let p = str(["file_path", "path", "filename", "file", "target_file"]) { return "Edit \(PathFormat.short(p))" }
            return "Edit"
        case "write", "write_file", "writefile", "create_file", "notebookedit", "notebook_edit":
            if let p = str(["file_path", "path", "filename", "file", "target_file"]) { return "Write \(PathFormat.short(p))" }
            return "Write"
        case "grep", "ripgrep", "grep_search", "search_files", "search":
            if let p = str(["pattern", "query", "regex", "q"]) { return "Grep \(truncate(p, 50))" }
            return "Grep"
        case "glob", "find", "file_search":
            if let p = str(["pattern", "glob", "path", "query"]) { return "Glob \(truncate(p, 50))" }
            return "Glob"
        case "ls", "list_dir", "list_files":
            if let p = str(["path", "dir", "directory"]) { return "List \(PathFormat.short(p))" }
            return "List"
        case "webfetch", "web_fetch", "fetch":
            if let u = str(["url"]) { return "WebFetch \(host(u))" }
            return "WebFetch"
        case "websearch", "web_search":
            if let q = str(["query", "q"]) { return "WebSearch: \(truncate(q, 50))" }
            return "WebSearch"
        case "todowrite", "todo_write", "update_todo_list", "todos":
            if let (done, total) = todoCounts(args: args) { return "Todos (\(done)/\(total))" }
            return "Todos"
        case "task", "taskcreate", "agent", "dispatch_agent", "new_task", "delegate_to_agent",
             "spawn_subagent":
            if let sub = str(["subagent_type", "agent_type", "description", "subject"]) {
                return display(name) + ": " + truncate(sub, 50)
            }
            return display(name)
        case "skill":
            // `skill` is what most hosts pass; OpenCode's native tool takes
            // `name`. Read the unambiguous one first.
            if let s = str(["skill", "name", "command"]) { return "Skill: \(s)" }
            return "Skill"
        default:
            guard let v = firstStringValue(args) else { return display(name) }
            // A live call titled by its own argument — codex-acp titles a shell
            // command with the command — would read "ls -la: ls -la". Its saved
            // copy is titled by the command alone; so is this.
            if v.trimmingCharacters(in: .whitespacesAndNewlines) == name.trimmingCharacters(in: .whitespacesAndNewlines) {
                return simplifyCommand(name)
            }
            return "\(display(name)): \(truncate(v, 50))"
        }
    }

    // Exact canonical-name buckets. Mirrors the web `classifyToolKind` /
    // `EXACT_TOOL_NAME_ALIASES` approach: match KNOWN names exactly rather than
    // substring-`contains`. The old `contains` heuristic mis-bucketed any MCP
    // tool whose name happened to embed a keyword — e.g. `mcp__db__run_query`
    // hit `contains("run")` → `.execute` → the Bash body dumped its raw JSON.
    // An unknown tool must fall through to `.other` so it renders structured
    // fields, not a guessed per-type body.
    private static let readNames: Set<String> = ["read", "read_file", "readfile", "read_text_file", "cat", "view"]
    private static let editNames: Set<String> = [
        "edit", "str_replace", "str_replace_editor", "str_replace_based_edit_tool",
        "apply_patch", "applypatch", "patch", "multiedit", "edit_file", "update_file",
        "write", "write_file", "writefile", "create_file", "notebookedit", "notebook_edit",
        "write_to_file", "replace_in_file",
    ]
    private static let searchNames: Set<String> = [
        "grep", "ripgrep", "grep_search", "search_files", "search", "searchtext", "search_text",
        "glob", "find", "file_search", "ls", "list_dir", "list_files", "list_code_definition_names",
    ]
    private static let executeNames: Set<String> = [
        "bash", "shell", "sh", "exec", "exec_command", "execute", "execute_command",
        "run_command", "command", "run_terminal_cmd", "terminal",
    ]
    private static let webNames: Set<String> = [
        "webfetch", "web_fetch", "fetch", "websearch", "web_search", "browser", "browser_action",
    ]
    private static let todoNames: Set<String> = ["todowrite", "todo_write", "update_todo_list", "todos"]
    // Agent-DISPATCH tools (spawn a sub-agent) — distinct from the task-MANAGEMENT
    // tools below, which manage a to-do list.
    // `spawn_subagent` is Grok's native sub-agent launcher. It has to be listed
    // explicitly: the history parser rewrites it to "Agent", but any path where
    // only the raw name survives (the `x.ai/tool.name` fallback, with no input to
    // classify from) reaches here — and no substring rule can rescue it, since
    // "subagent" has no word boundary before "agent".
    private static let taskNames: Set<String> = [
        "task", "agent", "dispatch_agent", "new_task", "spawn_subagent",
        "delegate_to_agent", "delegate_task", "subagent", "spawn_agent", "call_omo_agent",
    ]
    /// The harness task-management tools — a to-do list, NOT sub-agent dispatch.
    /// Bucketed separately so they render as an evolving checklist (`TaskListCard`)
    /// with checklist iconography instead of the agent-dispatch "person.2".
    private static let taskMgmtNames: Set<String> = [
        "taskcreate", "taskupdate", "tasklist", "taskget",
        "task_create", "task_update", "task_list", "task_get",
        "createtask", "updatetask", "listtasks", "gettask", "addtask",
    ]

    static func bucket(name: String, kind: String) -> ToolKindBucket {
        // These two win over the ACP `kind` hint below. codex announces both as
        // execute-kind tools — truthfully, they do run a shell — but neither
        // carries a command, so the Terminal card has nothing to show and the
        // header falls back to a bare "Bash". Their own bodies read the session
        // id / JS source the arguments actually carry.
        let builtin = codexBuiltin(name)
        if ShellSessionCall.isSessionToolName(builtin) { return .session }
        if builtin == CodexScriptCard.toolName { return .script }
        // The ACP `kind` hint (live tools carry an authoritative category) wins.
        switch kind.lowercased() {
        case "read": return .read
        case "edit", "write", "delete", "move": return .edit
        case "search": return .search
        case "execute", "command", "bash", "shell", "terminal": return .execute
        case "fetch", "web": return .web
        default: break
        }
        let n = canonical(name)
        if readNames.contains(n) { return .read }
        if todoNames.contains(n) { return .todo }
        if taskMgmtNames.contains(n) { return .taskMgmt }
        if taskNames.contains(n) { return .task }
        if editNames.contains(n) { return .edit }
        if searchNames.contains(n) { return .search }
        if executeNames.contains(n) { return .execute }
        if webNames.contains(n) { return .web }
        return .other
    }

    /// A grep-like search (as opposed to a `glob`/`ls` listing), for which an
    /// exit code of 1 means "no matches" rather than a failure.
    static func isGrepName(_ name: String) -> Bool {
        ["grep", "ripgrep", "grep_search", "search_files", "search", "searchtext", "search_text"]
            .contains(canonical(name))
    }

    /// Grok stamps the authoritative tool identity in `_meta["x.ai/tool"]`
    /// (`{name, kind, namespace, label}`). For its plan-mode tools this returns the
    /// canonical `enter_plan_mode` / `exit_plan_mode`; nil for every other Grok tool
    /// and every non-Grok host, so their existing name resolution is preserved.
    /// Keyed on the stable `kind` discriminator, which — unlike `title` — does not
    /// mutate across the tool_call lifecycle.
    static func grokPlanModeName(_ meta: AnyJSON?) -> String? {
        switch meta?["x.ai/tool"]?["kind"]?.string {
        case "enter_plan": return "enter_plan_mode"
        case "exit_plan": return "exit_plan_mode"
        default: return nil
        }
    }

    /// Plan-*mode* transition tools. Mirrors the web `isPlanModeToolName`:
    /// deliberately NOT the looser "contains plan" test, so Codex's `update_plan`
    /// (a real checklist) keeps its own rendering.
    static func isPlanModeName(_ name: String) -> Bool {
        switch canonical(name).replacingOccurrences(of: "_", with: "") {
        case "enterplanmode", "exitplanmode", "switchmode": return true
        default: return false
        }
    }

    static func icon(bucket: ToolKindBucket, name: String, input: String?) -> String {
        // A mode signal, not a work tool — same checklist glyph the plan node uses.
        if isPlanModeName(name) { return "checklist" }
        switch bucket {
        case .read: return "doc.text"
        case .edit: return "square.and.pencil"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .web: return "globe"
        case .todo: return "checklist"
        case .task: return "person.2"
        case .taskMgmt: return "checklist"
        case .script: return "curlybraces"
        case .session:
            // Sending keystrokes reads as input; everything else (including the
            // 99% of `write_stdin` calls that send nothing) is a poll on a
            // running session.
            let sendsInput = !(ShellSessionCall.parse(input: input)?.chars.isEmpty ?? true)
            return sendsInput ? "keyboard" : "timer"
        case .other: return "wrench.and.screwdriver"
        }
    }

    /// The session id an `exec_command`'s own output announced. Scoped to that
    /// one tool: the echo is a code-mode script's, and matching it anywhere else
    /// would badge unrelated cards that merely printed the words.
    static func announcedSession(name: String, output: String?) -> String? {
        guard codexBuiltin(name) == "exec_command", let output else { return nil }
        // The JSON envelope is unwrapped but the CLI header is deliberately NOT
        // stripped: `parseCliEnvelope` drops everything above the `Output:` line
        // — the announcement included. (The Rust parser reads it in the same
        // order, before its own clean.) The persisted path is already plain
        // text, so the unwrap is only for a live `{formatted_output, …}` result.
        let body = ToolOutputFormat.commandOutput(fromJSON: output) ?? output
        return ShellSessionFormat.announcedSessionId(in: body)
    }

    /// Gutter / card icon for a codeg-mcp companion tool.
    static func companionIcon(_ kind: CompanionKind) -> String {
        switch kind {
        case .delegate:         return "person.2"
        case .delegationStatus: return "arrow.triangle.2.circlepath"
        case .cancelDelegation: return "xmark.circle"
        case .askQuestion:      return "questionmark.bubble"
        }
    }

    static func diff(bucket: ToolKindBucket, input: String?, output: String?, content: String?, parsed: [String: Any]?) -> [DiffFile]? {
        guard bucket == .edit else { return nil }
        // Priority: live ACP content → persisted output (Claude) → raw input
        // (apply_patch) → synthesize from old/new strings.
        for candidate in [content, output, input].compactMap({ $0 }) {
            if UnifiedDiff.looksLikeDiff(candidate), let files = UnifiedDiff.parse(candidate) { return files }
        }
        if let args = effectiveArgs(parsed) {
            let oldS = (args["old_string"] as? String) ?? (args["old_str"] as? String)
            let newS = (args["new_string"] as? String) ?? (args["new_str"] as? String)
            if let oldS, let newS {
                let path = (args["file_path"] as? String) ?? (args["path"] as? String) ?? "edit"
                return synthesizeDiff(path: path, old: oldS, new: newS)
            }
        }
        return nil
    }

    // MARK: helpers

    /// codex's own built-in tool names, matched WITHOUT the `__`-prefix strip
    /// `canonical(_:)` applies. Those names are codex's alone and never arrive
    /// MCP-namespaced, whereas `canonical("mcp__docs__wait")` is `"wait"` — so
    /// canonicalizing here would hand somebody else's tool the session card and
    /// hide its real arguments. The web is the same: its `canonicalizeToolName`
    /// only folds separators, it does not strip MCP prefixes, so only the exact
    /// name (or the `functions.` namespace codex-acp aliases) ever matches.
    private static func codexBuiltin(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n.hasPrefix("functions.") ? String(n.dropFirst("functions.".count)) : n
    }

    private static func canonical(_ name: String) -> String {
        var n = name.lowercased()
        if let r = n.range(of: "__", options: .backwards) { n = String(n[r.upperBound...]) }
        return n
    }

    static func display(_ name: String) -> String {
        var n = name
        if let r = n.range(of: "__", options: .backwards) { n = String(n[r.upperBound...]) }
        return n
    }

    private static func editFileCount(args: [String: Any]?) -> Int? {
        if let changes = args?["changes"] as? [Any] { return changes.count }
        if let edits = args?["edits"] as? [Any] { return edits.count }
        if let patch = (args?["patch"] as? String) ?? (args?["input"] as? String), patch.contains("*** ") {
            let n = patch.components(separatedBy: "\n").filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("*** Add File:") || t.hasPrefix("*** Update File:") || t.hasPrefix("*** Delete File:")
            }.count
            if n > 0 { return n }
        }
        return nil
    }

    /// A title for a task-management call — used for the gutter marker / a11y; the
    /// `TaskListCard` computes its own header. Mirrors `TaskOpParse`'s name routing.
    private static func taskMgmtTitle(name: String, args: [String: Any]?) -> String {
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = args?[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        // A task id may be a JSON string OR number — match `TaskOpParse.idStr` so a
        // numeric `{ "taskId": 9 }` titles "Update task #9", not "Update task".
        func id(_ keys: [String]) -> String? {
            for k in keys {
                guard let v = args?[k] else { continue }
                if let s = v as? String, !s.isEmpty { return s }
                if let n = v as? NSNumber, !ToolJSONFormat.isBoolean(n) { return n.stringValue }
            }
            return nil
        }
        switch TaskOpParse.kind(of: name) {
        case .create:
            if let s = str(["subject", "title"]) { return "New task: " + truncate(s, 50) }
            return "New task"
        case .update:
            if let tid = id(["taskId", "task_id", "id"]) { return "Update task #\(tid)" }
            return "Update task"
        case .get:
            if let tid = id(["taskId", "task_id", "id"]) { return "Task #\(tid)" }
            return "Task details"
        case .list:
            return "Task list"
        case .none:
            return display(name)
        }
    }

    private static func todoCounts(args: [String: Any]?) -> (Int, Int)? {
        guard let todos = (args?["todos"] as? [[String: Any]]) ?? (args?["todoList"] as? [[String: Any]]) else { return nil }
        let total = todos.count
        let done = todos.filter { ($0["status"] as? String) == "completed" }.count
        return (done, total)
    }

    private static func firstStringValue(_ args: [String: Any]?) -> String? {
        guard let args else { return nil }
        let skip: Set<String> = ["id", "tool_use_id", "tool_call_id", "type"]
        for k in args.keys.sorted() where !skip.contains(k.lowercased()) {
            if let s = args[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func simplifyCommand(_ c: String) -> String {
        var cmd = c.trimmingCharacters(in: .whitespacesAndNewlines)
        // Peel nested shell wrappers like `/bin/zsh -lc '<cmd>'` or
        // `/usr/bin/env bash -c "<cmd>"` so the title is the real command, not
        // the launcher. Mirrors web `simplifyShellCommand` (loops for nesting).
        let wrapper = #"^(?:/usr/bin/env\s+)?(?:/[^\s]+/)?(?:bash|zsh|sh)\s+-l?c\s+"#
        for _ in 0..<6 {
            guard let r = cmd.range(of: wrapper, options: [.regularExpression, .caseInsensitive]) else { break }
            let inner = unwrapQuoted(cmd[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
            if inner.isEmpty || inner == cmd { break }
            cmd = inner
        }
        let firstLine = cmd.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? cmd
        return truncate(firstLine, 80)
    }

    /// Strip a single layer of matching surrounding quotes from an unwrapped
    /// shell argument (`'<cmd>'` / `"<cmd>"`), unescaping the double-quoted form.
    private static func unwrapQuoted(_ command: String) -> String {
        let t = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return t }
        if t.hasPrefix("'") && t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
        if t.hasPrefix("\"") && t.hasSuffix("\"") {
            return String(t.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }

    private static func host(_ url: String) -> String {
        if let u = URL(string: url), let h = u.host { return h }
        return truncate(url, 40)
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    private static func synthesizeDiff(path: String, old: String, new: String) -> [DiffFile] {
        var rows: [DiffRow] = []
        for l in old.split(separator: "\n", omittingEmptySubsequences: false) {
            rows.append(DiffRow(kind: .deleted, oldLine: nil, newLine: nil, text: String(l)))
        }
        for l in new.split(separator: "\n", omittingEmptySubsequences: false) {
            rows.append(DiffRow(kind: .added, oldLine: nil, newLine: nil, text: String(l)))
        }
        let dels = old.split(separator: "\n", omittingEmptySubsequences: false).count
        let adds = new.split(separator: "\n", omittingEmptySubsequences: false).count
        return [DiffFile(path: path, oldPath: nil, mode: .modified, additions: adds, deletions: dels,
                         hunks: [DiffHunk(header: nil, rows: rows)])]
    }
}

/// Shorten a file path to its last two segments ("src/foo.ts").
enum PathFormat {
    static func short(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: .whitespaces)
        let comps = clean.split(separator: "/").map(String.init)
        if comps.count <= 2 { return comps.joined(separator: "/") }
        return comps.suffix(2).joined(separator: "/")
    }
}
