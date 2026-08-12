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

    var id: String {
        switch self {
        case .text(let run): return "t-\(run.id)"
        case .thinking(let run): return "k-\(run.id)"
        case .tool(let call): return "x-\(call.id)"
        }
    }
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
    /// The agent's live plan/TODO list (`plan_update`). Replaced wholesale per
    /// event (each carries the full list); rendered as a checklist above the turn.
    var livePlan: [PlanEntry] = []
    /// Fatal error surfaced inline at the end of the turn.
    var errorMessage: String?
    /// Server-supplied diagnostic evidence for that error (agent stderr tail,
    /// unparsed-update counts) — shown behind a disclosure, never in the one-line
    /// message, mirroring the web's split between the alert body and the composer
    /// tooltip. See ``AcpEvent/error(message:code:details:)``.
    var errorDetails: String?
    /// Whether the turn is still receiving events (drives the pulse).
    var isStreaming = true
    /// Most recent stop reason once the turn completes.
    var stopReason: String?

    init(id: String = "live-\(UUID().uuidString)") {
        self.id = id
    }

    /// True before any content has streamed — used to show a "waiting" shimmer.
    var isEmpty: Bool { segments.isEmpty && errorMessage == nil && livePlan.isEmpty }

    /// Replace the live plan from a `plan_update` event (or snapshot `plan` block).
    func updatePlan(_ entries: [PlanEntry]) {
        livePlan = entries
    }

    // MARK: - Mutation (event handlers call these on the main actor)

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
    func snapshotAsMessageTurn() -> MessageTurn {
        var blocks: [ContentBlock] = []
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
                // The snapshot always pairs a result below, so the status slot has
                // nothing to add — the pair already states the outcome.
                blocks.append(.toolUse(id: call.id, name: call.title, inputPreview: call.rawInput,
                                       status: .unknown, meta: call.meta))
                let output = call.rawOutput.isEmpty ? call.content : call.rawOutput
                blocks.append(.toolResult(id: call.id, outputPreview: output, isError: call.isError,
                                          agentStats: nil))
            }
        }
        return MessageTurn(id: id, role: .assistant, blocks: blocks, timestamp: Date())
    }
}
