import SwiftUI
import Observation

/// The streaming state of a single in-flight tool call, keyed by its ACP tool
/// id. Mutated in place as `tool_call_update` events arrive so the UI updates
/// granularly without rebuilding the whole turn.
@MainActor
@Observable
final class LiveToolCall: Identifiable {
    nonisolated let id: String
    var title: String
    var kind: String
    var status: String
    /// Echoed argument JSON (preview), shown under the tool name.
    var rawInput: String?
    /// Accumulated output text. `tool_call_update` with `append:true` appends,
    /// otherwise the value replaces.
    var rawOutput: String
    /// ACP "rendered content" — for an edit this is the unified diff. Kept so the
    /// card can render a red/green diff live (previously this field was dropped).
    var content: String?
    /// ACP `meta` — for `delegate_to_agent` carries `codeg.delegation`, whose
    /// terminal status the delegate card prefers over the running ack. Patched in
    /// place when a `tool_call_update` carries a newer meta.
    var meta: AnyJSON?
    /// The sub-agent transcript belonging to this call, when it launched one.
    /// Empty for every ordinary tool. See ``SubAgentRun``.
    var transcript: [SubAgentRun] = []

    init(id: String, title: String, kind: String, status: String, rawInput: String?, rawOutput: String, content: String? = nil, meta: AnyJSON? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.content = content
        self.meta = meta
    }

    /// Append a sub-agent delta, merging into the trailing run when it is the
    /// same kind.
    ///
    /// Deliberately NOT the backend's block predicate, which also splits on any
    /// intervening block from another thread: main → sub → main → sub yields two
    /// sub-agent blocks there and one merged run here. Merging is right for this
    /// renderer — the sub-agent wrote one continuous passage and the main
    /// thread's interleaved chunks are in a different view entirely, so honoring
    /// the backend's split would cut a sentence in half for no reason. The same
    /// holds in reverse for `segments`, whose main-thread runs merge across the
    /// sub-agent chunks routed out of them. Live and snapshot still converge:
    /// `buildLiveTurn` defers parented blocks to a second pass, so it reproduces
    /// exactly these boundaries rather than the wire's.
    func appendTranscript(_ delta: String, thinking: Bool) {
        guard !delta.isEmpty else { return }
        switch transcript.last {
        case .text(let run) where !thinking: run.append(delta)
        case .thinking(let run) where thinking: run.append(delta)
        default: transcript.append(thinking ? .thinking(LiveTextRun(delta)) : .text(LiveTextRun(delta)))
        }
    }

    /// Publish every transcript run's pending coalesce (see ``LiveTurn/flushAllText()``).
    func flushTranscript() {
        for entry in transcript { entry.run.flushNow() }
    }

    /// True once the agent reports the call finished (success or failure).
    var isFinished: Bool {
        switch status {
        case "completed", "failed", "error", "cancelled", "canceled": return true
        default: return false
        }
    }

    var isError: Bool {
        status == "failed" || status == "error"
    }

    /// SF Symbol chosen from the ACP `kind` hint, falling back to a generic
    /// wrench. Mirrors the kinds emitted by the codeg agents.
    var symbol: String {
        switch kind.lowercased() {
        case "read", "fetch": return "doc.text"
        case "edit", "write": return "square.and.pencil"
        case "search", "grep", "find": return "magnifyingglass"
        case "execute", "command", "bash", "shell", "terminal": return "terminal"
        case "think": return "brain"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "web", "browser": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// One merged run of a SUB-AGENT's own prose or reasoning, streamed under the
/// Agent tool call that launched it.
///
/// Sub-agent output is attributed by `_meta.claudeCode.parentToolUseId` and
/// arrives interleaved with the main thread's on a single wire. It is the
/// sub-agent talking to itself, not part of the reply the user asked for, so it
/// is routed here instead of into ``LiveTurn/segments``.
///
/// LIVE ONLY. The backend persists main-thread blocks exclusively
/// (`parent_tool_use_id: None`), so a transcript exists while the turn streams
/// and is gone once it settles — matching the web client, and deliberately not
/// reconstructible from history.
enum SubAgentRun: Identifiable {
    case text(LiveTextRun)
    case thinking(LiveTextRun)

    var run: LiveTextRun {
        switch self {
        case .text(let run), .thinking(let run): return run
        }
    }

    var isThinking: Bool {
        if case .thinking = self { return true }
        return false
    }

    var id: String { (isThinking ? "k-" : "t-") + run.id }
}

/// One ordered piece of an in-flight assistant turn. The live turn is a sequence
/// of these so text, reasoning, and tool calls render in arrival order, exactly
/// as a finalized transcript would. The associated reference types expose a
/// `nonisolated let id`, so the enum's `id` needs no actor hop.
enum LiveSegment: Identifiable {
    case text(LiveTextRun)
    case thinking(LiveTextRun)
    case tool(LiveToolCall)
    /// A message the user inserted into this turn (native steering). It ends
    /// the reply so far, and what follows is the reply to it.
    case steering(SteeredMessage)
    /// The agent's plan, standing where it last revised it
    /// (`LiveTurn.updatePlan`). At most one per turn.
    case plan([PlanEntry])

    var id: String {
        switch self {
        case .text(let run): return "t-\(run.id)"
        case .thinking(let run): return "k-\(run.id)"
        case .tool(let call): return "x-\(call.id)"
        case .steering(let message): return "s-\(message.id)"
        case .plan: return "p"
        }
    }
}

/// A user message inserted into a running turn (a delivered ``FeedbackItem``).
struct SteeredMessage: Hashable, Sendable {
    let id: String
    let text: String
    let at: Date
}

/// A growing run of text (either assistant prose or reasoning). A reference type
/// so appending a delta mutates in place and SwiftUI re-renders just this run.
///
/// Deltas land token-by-token, but the *published* `text` is coalesced to a
/// ~50ms cadence so the view re-parses (block Markdown) at most ~20×/sec instead
/// of once per token — the streaming path now renders formatted Markdown live
/// (`MarkdownContent`), and re-parsing the whole accumulated reply per token
/// would be O(n²) main-thread work. The raw `buffer` is always current (so
/// snapshots never lose the tail); `text` trails it by up to one coalesce window.
@MainActor
@Observable
final class LiveTextRun: Identifiable {
    nonisolated let id = UUID().uuidString

    /// What views render. Published at most ~every 50ms while streaming.
    private(set) var text: String

    /// The full accumulated text, updated synchronously on every delta. NOT
    /// observed, so appends don't invalidate views between flushes; read via
    /// `fullText` for snapshotting.
    @ObservationIgnored private var buffer: String
    /// Pending coalesce task; non-nil means a flush is already scheduled.
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// Coalesce window for streamed text, scaled with the accumulated length. Each
    /// flush re-parses the whole buffer (block Markdown), which is ~O(n), so a fixed
    /// 50ms cadence makes the stream O(n²). Short replies — the common case — stay
    /// snappy at 50ms; a long reply relaxes toward ~140ms, dropping the re-parse
    /// rate as the per-parse cost rises. `flushNow()` still publishes the complete
    /// text on finalize, so this only trades a little tail latency, never content.
    private var coalesceWindow: Duration {
        switch buffer.utf8.count {
        case ..<4_000:  return .milliseconds(50)
        case ..<16_000: return .milliseconds(90)
        default:        return .milliseconds(140)
        }
    }

    init(_ text: String) {
        self.text = text
        self.buffer = text
    }

    /// Authoritative full content, regardless of any pending flush. Snapshots and
    /// finalization read this so the last partial chunk is never dropped.
    var fullText: String { buffer }

    /// Append a streamed delta. The buffer updates immediately; the observed
    /// `text` is published on the next coalesce tick.
    func append(_ delta: String) {
        buffer += delta
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }   // leading-guard: one task per window
        let window = coalesceWindow              // sampled at schedule time
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard let self else { return }
            self.flushTask = nil
            if self.text != self.buffer { self.text = self.buffer }   // trailing publish
        }
    }

    /// Publish the buffer immediately and cancel any pending coalesce. Call when
    /// the turn finalizes / fails / is cancelled so the finalized render sees the
    /// complete text with no trailing reflow.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        if text != buffer { text = buffer }
    }
}

/// The mutable, observable model for the assistant reply that is currently
/// streaming. Built optimistically when the user sends, mutated as ACP events
/// arrive, then converted to an immutable `MessageTurn` on completion.
@MainActor
@Observable
final class LiveTurn: Identifiable {
    nonisolated let id: String
    private(set) var segments: [LiveSegment] = []
    /// Tool-call lookup so `tool_call_update` finds its target in O(1).
    private var toolIndex: [String: LiveToolCall] = [:]
    /// Fatal error surfaced inline at the end of the turn.
    var errorMessage: String?
    /// Server-supplied diagnostic evidence for that error (agent stderr tail,
    /// unparsed-update counts) — shown behind a disclosure, never in the one-line
    /// message, mirroring the web's split between the alert body and the composer
    /// tooltip. See ``AcpEvent/error(message:code:details:)``.
    var errorDetails: String?
    /// The latest NON-fatal `error` this turn received (see ``AcpErrorRoute``),
    /// kept so that if the connection then dies — the backend follows a
    /// terminal error with `status_changed: error`, which carries no text — the
    /// failure line says why instead of a generic "the connection errored".
    /// Not rendered on its own; the notice already showed it.
    var lastNonFatalError: (message: String, details: String?)?
    /// `errorMessage` is the agent's OWN account of the failure (an `error`
    /// with no code: a prompt it rejected), as opposed to codeg's verdict
    /// (`turn_failed_*`). One account per turn, and the agent's words win
    /// whichever arrives first — mirrors the web's `TURN_FAILED`.
    var errorFromAgent = false
    /// `errorMessage` is the local "Cancelled." placeholder, not a failure —
    /// so it is not carried into the promoted snapshot as one.
    var errorIsCancellation = false
    /// Whether the turn is still receiving events (drives the pulse).
    var isStreaming = true
    /// Most recent stop reason once the turn completes.
    var stopReason: String?
    /// The highest event `seq` applied to this turn — from the attach
    /// snapshot's cursor, then every envelope. A reconnect resumes from it
    /// (`since_seq`), so the server replays what the socket missed instead of
    /// the deltas being lost; and an event at or below it is a duplicate of one
    /// already applied. Not observed by any view.
    @ObservationIgnored var lastSeq: UInt64?
    /// The server has started THIS turn: its `prompting` status, the echo of
    /// this send's own prompt, or a reconnect snapshot running that prompt.
    /// Until then an idle connection means the turn has not started, not that
    /// it has ended — and what streams belongs to the turn before it (an
    /// agent's own turn the server closes just ahead of this prompt), so
    /// none of it is this reply's. A reattach owns the running turn from the
    /// start, so a turn rebuilt from a snapshot is born started.
    @ObservationIgnored var serverTurnStarted = false
    /// The `clientMessageId` this send's prompt went out with. The server
    /// stamps it on the turn's `user_message` (and the snapshot's
    /// `pending_user_message`), which is what tells this prompt's turn from
    /// another client's or the agent's own.
    @ObservationIgnored var clientMessageId: String?

    init(id: String = "live-\(UUID().uuidString)") {
        self.id = id
    }

    /// True before any content has streamed — used to show a "waiting" shimmer.
    /// (The plan is one of the segments.)
    var isEmpty: Bool { segments.isEmpty && errorMessage == nil }

    /// Take over another turn's streamed content wholesale — used when a
    /// reconnect could not be replayed (the gap was too large, or the cursor
    /// fell out of the server's ring buffer) and the server sent its snapshot
    /// of the in-flight reply instead. That snapshot is the authoritative whole
    /// of what was streamed, so it REPLACES what this turn holds rather than
    /// being appended to it. The turn keeps its identity, which is what every
    /// `liveTurn === live` ownership check on the screen keys on.
    func adoptContent(from other: LiveTurn) {
        for segment in segments {
            if case .text(let run) = segment { run.flushNow() }
            if case .thinking(let run) = segment { run.flushNow() }
        }
        segments = other.segments
        steeredIDs = other.steeredIDs
        toolIndex = other.toolIndex
    }

    /// This round failed here (as opposed to being cancelled, or not failing).
    var failedLocally: Bool { errorMessage != nil && !errorIsCancellation }

    // MARK: - Plan

    /// The id of the call the plan is recorded as: the turn handed off keeps
    /// it as a `PlanParse.handoffToolName` call of this id, and the timeline
    /// keys the plan's row by it, live and handed off alike — so the row (and
    /// whether the reader collapsed it) survives the hand-off.
    var planCallID: String { "\(id)-plan" }

    /// The agent's plan as it stands, if it has one.
    var currentPlan: [PlanEntry]? {
        for segment in segments {
            if case .plan(let entries) = segment { return entries }
        }
        return nil
    }

    /// The agent's plan, as of now — a `plan_update` event (each carries the
    /// full list), or a reattach snapshot's `plan` block.
    ///
    /// It stands where it was last revised, as the web's `PLAN_UPDATE` keeps
    /// it: the old one is taken out and the new one goes at the end, so the
    /// plan moves to the point in the reply where the agent revised it rather
    /// than staying pinned where it first appeared. An empty one removes it.
    /// A snapshot replays its blocks in order, so a reattach puts the plan
    /// back where the server's copy holds it.
    func updatePlan(_ entries: [PlanEntry]) {
        let at = segments.firstIndex { if case .plan = $0 { return true }; return false }
        if let at, at == segments.count - 1, case .plan(let current) = segments[at], current == entries {
            return   // already the latest word, already last
        }
        guard at != nil || !entries.isEmpty else { return }
        if let at {
            segments.remove(at: at)
            rejoinRuns(at: at)
        }
        if !entries.isEmpty { segments.append(.plan(entries)) }
    }

    /// What streamed either side of a plan that moved away was ONE run of
    /// prose (or of thought) the plan cut in two — appends join a run
    /// otherwise — so it is joined again, or a sentence split mid-word would
    /// draw as two paragraphs. The later run's text goes onto the earlier
    /// run, published at once so the moved words never blink out for a
    /// coalesce window; the later run's row goes away.
    private func rejoinRuns(at index: Int) {
        guard index > 0, index < segments.count else { return }
        switch (segments[index - 1], segments[index]) {
        case (.text(let before), .text(let after)), (.thinking(let before), .thinking(let after)):
            before.append(after.fullText)
            before.flushNow()
            segments.remove(at: index)
        default:
            break
        }
    }

    // MARK: - Mutation (event handlers call these on the main actor)

    /// The ids of the messages inserted into this turn. Stored rather than
    /// derived from `segments`, so the note strips that read it are not
    /// re-rendered by every segment the reply appends.
    private(set) var steeredIDs: Set<String> = []

    /// Insert a steered user message at this point of the stream. Idempotent by
    /// id: the submit broadcast reaches the sender too.
    func insertSteering(_ message: SteeredMessage) {
        guard !steeredIDs.contains(message.id) else { return }
        flushAllText()
        segments.append(.steering(message))
        steeredIDs.insert(message.id)
    }

    func appendText(_ delta: String, parentToolUseId: String? = nil) {
        guard !delta.isEmpty else { return }
        if let parentToolUseId {
            routeToSubAgent(delta, parent: parentToolUseId, thinking: false)
            return
        }
        if case .text(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.text(LiveTextRun(delta)))
        }
    }

    func appendThinking(_ delta: String, parentToolUseId: String? = nil) {
        guard !delta.isEmpty else { return }
        if let parentToolUseId {
            routeToSubAgent(delta, parent: parentToolUseId, thinking: true)
            return
        }
        if case .thinking(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.thinking(LiveTextRun(delta)))
        }
    }

    /// Sub-agent output goes to the card of the Agent call that launched it,
    /// never into the main reply.
    ///
    /// An unknown parent means the chunk is out-of-turn residue — typically an
    /// async sub-agent still streaming after its parent turn settled — and is
    /// dropped. The parent `tool_call` always precedes its sub-agent's chunks on
    /// the seq-ordered wire, so a chunk that still belonged to this turn would
    /// have found it. Dropping also bounds memory: orphan text never accumulates.
    private func routeToSubAgent(_ delta: String, parent: String, thinking: Bool) {
        toolIndex[parent]?.appendTranscript(delta, thinking: thinking)
    }

    /// Flush every text/reasoning run's pending coalesce immediately. Called when
    /// the turn ends so the finalized render sees complete text (no trailing
    /// reflow) and a snapshot taken right after is whole.
    func flushAllText() {
        for segment in segments {
            switch segment {
            case .text(let run), .thinking(let run): run.flushNow()
            case .tool(let call): call.flushTranscript()
            case .steering, .plan: break
            }
        }
    }

    func upsertToolCall(id: String, title: String, kind: String, status: String, rawInput: String?, rawOutput: String?, content: String?, meta: AnyJSON? = nil) {
        if let existing = toolIndex[id] {
            existing.title = title.isEmpty ? existing.title : title
            if !kind.isEmpty { existing.kind = kind }
            if !status.isEmpty { existing.status = status }
            if let rawInput { existing.rawInput = rawInput }
            if let rawOutput { existing.rawOutput = rawOutput }
            if let content { existing.content = content }
            if let meta { existing.meta = meta }
        } else {
            let call = LiveToolCall(
                id: id,
                title: title.isEmpty ? "Tool" : title,
                kind: kind,
                status: status.isEmpty ? "in_progress" : status,
                rawInput: rawInput,
                rawOutput: rawOutput ?? "",
                content: content,
                meta: meta
            )
            toolIndex[id] = call
            segments.append(.tool(call))
        }
    }

    func updateToolCall(id: String, title: String?, status: String?, rawInput: String?, rawOutput: String?, content: String?, append: Bool, meta: AnyJSON? = nil) {
        guard let call = toolIndex[id] else {
            // An update for a tool we never saw a `tool_call` for — materialize it
            // so its input/output is not lost.
            upsertToolCall(
                id: id,
                title: title ?? "",
                kind: "",
                status: status ?? "",
                rawInput: rawInput,
                rawOutput: rawOutput,
                content: content,
                meta: meta
            )
            return
        }
        if let title, !title.isEmpty { call.title = title }
        if let status, !status.isEmpty { call.status = status }
        // Capture arguments arriving on an update (or replacing a partial input)
        // so companion classification can key off the input shape.
        if let rawInput, !rawInput.isEmpty { call.rawInput = rawInput }
        if let content { call.content = content }
        // A newer meta (e.g. the delegate lifecycle's terminal `codeg.delegation`)
        // replaces the prior one so the live delegate card stops reading "running".
        if let meta { call.meta = meta }
        if let rawOutput {
            if append { call.rawOutput += rawOutput } else { call.rawOutput = rawOutput }
        }
    }

    /// The live tool call a permission request is about, matched by the id the
    /// request names (web `findLiveToolCallInfo`). Nil when the request names no
    /// id or this turn never saw the call.
    func permissionLiveInfo(for toolCall: AnyJSON) -> PermissionLiveInfo? {
        guard let id = PermissionLiveMerge.toolCallId(toolCall), let call = toolIndex[id] else { return nil }
        return PermissionLiveInfo(toolCallId: call.id, title: call.title, kind: call.kind,
                                  rawInput: call.rawInput, meta: call.meta)
    }

    /// A permission request is about call `id` (web `PERMISSION_REQUEST`): the
    /// input it names fills a call that hasn't sent its own yet, and a call
    /// the request comes ahead of is announced here, pending, so the step the
    /// user is asked about stands on the rail. Its own `tool_call` later
    /// takes the entry over. Returns whether anything changed.
    @discardableResult
    func noteAwaitedCall(id: String, title: String, kind: String, rawInput: String) -> Bool {
        if let existing = toolIndex[id] {
            guard existing.rawInput?.isEmpty ?? true else { return false }
            existing.rawInput = rawInput
            return true
        }
        upsertToolCall(id: id, title: title, kind: kind, status: "pending",
                       rawInput: rawInput, rawOutput: nil, content: nil)
        return true
    }

    /// Short human-readable label for the currently active tool, for the compose
    /// status line ("Running Edit…").
    var activeToolTitle: String? {
        for segment in segments.reversed() {
            if case .tool(let call) = segment, !call.isFinished {
                return call.title
            }
        }
        return nil
    }

    /// Snapshot this (finalized) turn as an immutable assistant `MessageTurn`, so a
    /// reply that finished streaming but isn't yet in the server transcript can be
    /// folded into the persisted list — surviving a subsequent send — until a
    /// reconcile replaces it with the authoritative copy. Segment→block mapping
    /// mirrors `MessageRender.adaptLive` so the folded copy renders the same; a
    /// tool's diff `content` rides in the result preview (its only persisted slot)
    /// when there's no separate output text.
    ///
    /// A message the user steered into the turn splits it, as it does on
    /// screen: the reply so far, the user's message, then the reply to it.
    /// Empty replies are left out.
    ///
    /// The plan is kept where it stood, as the call the transcript records a
    /// plan by (`PlanParse.handoffToolName`, id `planCallID`), which the
    /// persisted path draws as the same plan card in the same row — so it
    /// doesn't vanish as the turn ends and come back elsewhere once the
    /// transcript is read again. Kimi's own todo writes go the way the live
    /// adapter draws them (`MessageRender.adaptLive`).
    func snapshotAsMessageTurns() -> [MessageTurn] {
        var out: [MessageTurn] = []
        var blocks: [ContentBlock] = []
        var chunk = 0
        let hasPlan = currentPlan != nil
        func closeReply() {
            if !blocks.isEmpty {
                out.append(MessageTurn(id: chunk == 0 ? id : "\(id)~\(chunk)", role: .assistant,
                                       blocks: blocks, timestamp: Date()))
            }
            blocks = []
            chunk += 1
        }
        for segment in segments {
            switch segment {
            case .text(let run):
                if !run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(run.fullText))
                }
            case .thinking(let run):
                if !run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.thinking(run.fullText))
                }
            case .tool(let call):
                if !call.isError, let todos = PlanParse.kimiTodoWriteEntries(call.rawInput) {
                    // The plan stands for it; with none, it is the plan.
                    if !hasPlan {
                        blocks.append(.toolUse(id: call.id, name: PlanParse.handoffToolName,
                                               inputPreview: PlanParse.handoffInput(todos),
                                               status: .completed, meta: nil))
                    }
                    continue
                }
                // The snapshot always pairs a result below, which states the
                // outcome. A `failed` status is kept all the same: it is what
                // tells codex's search that found nothing (a bare live `failed`)
                // from a real failure (`GrepNoMatch`), so the folded copy draws it
                // as the live one did.
                blocks.append(.toolUse(id: call.id, name: call.title, inputPreview: call.rawInput,
                                       status: call.status == "failed" ? .failed : .unknown, meta: call.meta))
                let output = call.rawOutput.isEmpty ? call.content : call.rawOutput
                blocks.append(.toolResult(id: call.id, outputPreview: output, isError: call.isError,
                                          agentStats: nil))
            case .steering(let message):
                closeReply()
                out.append(MessageTurn(id: "steer-\(message.id)", role: .user,
                                       blocks: [.text(message.text)], timestamp: message.at))
            case .plan(let entries):
                // No result to pair: the plan card states no outcome.
                blocks.append(.toolUse(id: planCallID, name: PlanParse.handoffToolName,
                                       inputPreview: PlanParse.handoffInput(entries),
                                       status: .completed, meta: nil))
            }
        }
        // A failed round keeps saying why after it is folded in — the same
        // failure line a reload draws from the server's `turn_error`. (Its
        // evidence disclosure is live-only: the record has no slot for it.)
        if let failure = errorMessage, !errorIsCancellation,
           !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.turnError(failure))
        }
        closeReply()
        return out
    }
}
