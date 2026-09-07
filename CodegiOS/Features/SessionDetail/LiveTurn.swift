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

/// A message the user sent WHILE the turn was running, delivered to the agent
/// over the live-steering channel. Not agent output: it marks the point in the
/// stream where the user interrupted, so the transcript can show it as a user
/// message there and start the reply to it as a fresh run.
struct LiveUserMessage {
    /// The feedback note's id. Also the dedup key — the server broadcasts a
    /// submission to every attached client, including the one that sent it.
    let id: String
    let text: String
    /// When the note was created (its `created_at`), so the message is stamped
    /// with the moment it was sent rather than the start of the reply it
    /// interrupted.
    let sentAt: Date
}

/// One ordered piece of an in-flight assistant turn. The live turn is a sequence
/// of these so text, reasoning, tool calls, and any message the user sent
/// mid-turn render in arrival order, exactly as a finalized transcript would.
/// The associated reference types expose a `nonisolated let id`, so the enum's
/// `id` needs no actor hop.
enum LiveSegment: Identifiable {
    case text(LiveTextRun)
    case thinking(LiveTextRun)
    case tool(LiveToolCall)
    case userMessage(LiveUserMessage)

    var id: String {
        switch self {
        case .text(let run): return "t-\(run.id)"
        case .thinking(let run): return "k-\(run.id)"
        case .tool(let call): return "x-\(call.id)"
        case .userMessage(let message): return "u-\(message.id)"
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
    /// Feedback-note ids already spliced in as mid-turn user messages, so the
    /// submit broadcast can be applied idempotently.
    private var userMessageIDs: Set<String> = []
    /// The agent's live plan/TODO list (`plan_update`). Replaced wholesale per
    /// event (each carries the full list); rendered as a checklist above the turn.
    var livePlan: [PlanEntry] = []
    /// Fatal error surfaced inline at the end of the turn.
    var errorMessage: String?
    /// Whether the turn is still receiving events (drives the pulse).
    var isStreaming = true
    /// Most recent stop reason once the turn completes.
    var stopReason: String?

    init(id: String = "live-\(UUID().uuidString)") {
        self.id = id
    }

    /// True before any content has streamed — used to show a "waiting" shimmer.
    var isEmpty: Bool { segments.isEmpty && errorMessage == nil && livePlan.isEmpty }

    /// True while there is nothing from the agent to show yet: before the turn's
    /// first content, and again right after a mid-turn user message until the
    /// reply to it starts. Drives the "waiting" shimmer at the tail of the turn,
    /// so interrupting the agent doesn't leave the transcript looking stalled.
    var isAwaitingOutput: Bool {
        if case .userMessage? = segments.last { return true }
        return isEmpty
    }

    /// Replace the live plan from a `plan_update` event (or snapshot `plan` block).
    func updatePlan(_ entries: [PlanEntry]) {
        livePlan = entries
    }

    // MARK: - Mutation (event handlers call these on the main actor)

    func appendText(_ delta: String) {
        guard !delta.isEmpty else { return }
        if case .text(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.text(LiveTextRun(delta)))
        }
    }

    func appendThinking(_ delta: String) {
        guard !delta.isEmpty else { return }
        if case .thinking(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.thinking(LiveTextRun(delta)))
        }
    }

    /// Splice a message the user sent mid-turn into the stream at the point the
    /// agent received it. It ends the run the agent was writing, so the reply to
    /// it starts a fresh one instead of continuing the same paragraph — the same
    /// split the persisted transcript makes for a mid-turn `user_message_chunk`,
    /// so the live view and a reload agree.
    ///
    /// Idempotent by note id: the submit is broadcast to every attached client,
    /// and one of them may be the sender.
    func appendUserMessage(id: String, text: String, sentAt: Date) {
        guard !text.isEmpty, !userMessageIDs.contains(id) else { return }
        userMessageIDs.insert(id)
        segments.append(.userMessage(LiveUserMessage(id: id, text: text, sentAt: sentAt)))
    }

    /// Flush every text/reasoning run's pending coalesce immediately. Called when
    /// the turn ends so the finalized render sees complete text (no trailing
    /// reflow) and a snapshot taken right after is whole.
    func flushAllText() {
        for segment in segments {
            switch segment {
            case .text(let run), .thinking(let run): run.flushNow()
            case .tool, .userMessage: break
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

    /// Snapshot this (finalized) turn as immutable `MessageTurn`s, so a reply that
    /// finished streaming but isn't yet in the server transcript can be folded into
    /// the persisted list — surviving a subsequent send — until a reconcile replaces
    /// it with the authoritative copy. Segment→block mapping mirrors
    /// `MessageRender.adaptLive` so the folded copy renders the same; a tool's diff
    /// `content` rides in the result preview (its only persisted slot) when there's
    /// no separate output text.
    ///
    /// Usually one assistant turn. A message the user sent mid-turn splits it, the
    /// way the server's own projection does, so the folded copy keeps the message
    /// in place and the two halves of the reply don't run together. Turns with no
    /// renderable blocks are omitted: a turn can be non-empty *solely* because of an
    /// inline error / "Cancelled." message, which `ContentBlock` has no case for,
    /// and folding in that zero-block turn would render as "No content".
    func snapshotAsMessageTurns() -> [MessageTurn] {
        var out: [MessageTurn] = []
        var blocks: [ContentBlock] = []

        func flushAssistant() {
            guard !blocks.isEmpty else { return }
            // The first turn keeps the live turn's own id so a `List` row that was
            // rendering the stream keeps its identity across the handoff.
            out.append(MessageTurn(
                id: out.isEmpty ? self.id : "\(self.id)#\(out.count)",
                role: .assistant,
                blocks: blocks,
                timestamp: Date()
            ))
            blocks = []
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
                blocks.append(.toolUse(id: call.id, name: call.title, inputPreview: call.rawInput, meta: call.meta))
                let output = call.rawOutput.isEmpty ? call.content : call.rawOutput
                blocks.append(.toolResult(id: call.id, outputPreview: output, isError: call.isError))
            case .userMessage(let message):
                flushAssistant()
                out.append(MessageTurn(
                    id: "u-\(message.id)",
                    role: .user,
                    blocks: [.text(message.text)],
                    timestamp: message.sentAt
                ))
            }
        }
        flushAssistant()
        return out
    }
}
