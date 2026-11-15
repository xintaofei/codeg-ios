import Foundation

// MARK: - Background sub-agents

/// One launched-but-unresolved background task, as the producer of
/// `background_activity` accounts it (Rust `BackgroundOutstandingTask`): the
/// Claude transcript watcher, or OpenCode / Grok live state. Every event and
/// snapshot carries the WHOLE set — state, not a delta.
/// What Claude's transcript watcher saw happen OUT of turn in one batch
/// (`background_activity`): background completions, the agent's work after
/// them, cron and loop turns. None of it produces ACP wire events — the
/// transcript is the only place it shows — so the batch carries the turns the
/// server's watcher read off it (`BackgroundOverlays`).
struct BackgroundOutOfTurn: Hashable, Sendable {
    /// Out-of-turn turns parsed from the transcript tail (re-sent whole as
    /// they grow), counting any this build could not read.
    var turnCount = 0
    /// The ones it could, upserted by id into the screen's overlay.
    var turns: [MessageTurn] = []
    /// How far the transcript was read (a byte offset): a detail read at or
    /// past it holds these turns, which retires them from the overlay.
    var watermark: Int64 = 0
    /// The agent session the watcher reads.
    var sessionID: String?
    /// Background tasks a `<task-notification>` settled in this batch.
    var settled: [BackgroundSettled] = []

    var isEmpty: Bool { turnCount == 0 && settled.isEmpty }
}

/// One background task settled by a `<task-notification>` (Rust
/// `BackgroundSettledInfo`).
struct BackgroundSettled: Hashable, Sendable, Decodable {
    var taskId: String
    /// The notification's status verbatim (`completed` on success).
    var status: String
    var summary: String?
    /// The task will notify again — still alive, so not "finished".
    var interim: Bool
    /// The launching call, whose card the settle flips in place.
    var toolUseId: String?
    /// The notification's `<result>` markdown.
    var result: String?

    init(taskId: String, status: String, summary: String? = nil, interim: Bool = false,
         toolUseId: String? = nil, result: String? = nil) {
        self.taskId = taskId
        self.status = status
        self.summary = summary
        self.interim = interim
        self.toolUseId = toolUseId
        self.result = result
    }

    private enum CodingKeys: String, CodingKey { case taskId, status, summary, interim, toolUseId, result }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = ((try? c.decodeIfPresent(String.self, forKey: .taskId)) ?? nil) ?? ""
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        interim = ((try? c.decodeIfPresent(Bool.self, forKey: .interim)) ?? nil) ?? false
        toolUseId = ((try? c.decodeIfPresent(String.self, forKey: .toolUseId)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        result = (try? c.decodeIfPresent(String.self, forKey: .result)) ?? nil
    }
}

struct BackgroundOutstandingTask: Hashable, Sendable {
    var taskId: String
    /// `agent` or `shell`. A plain string so a future kind can't fail a decode.
    var kind: String
    /// The tool call that launched it, when the producer saw the launch.
    var toolUseId: String?
    /// The launch's own description of the task — the row's title.
    var description: String?
    /// When the producer first saw it launched (or resumed), Unix ms.
    var startedAtMs: Int64
}

extension BackgroundOutstandingTask: Decodable {
    private enum CodingKeys: String, CodingKey { case taskId, kind, toolUseId, description, startedAtMs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = ((try? c.decodeIfPresent(String.self, forKey: .taskId)) ?? nil) ?? ""
        kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? ""
        toolUseId = (try? c.decodeIfPresent(String.self, forKey: .toolUseId)) ?? nil
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        startedAtMs = ((try? c.decodeIfPresent(Int64.self, forKey: .startedAtMs)) ?? nil) ?? 0
    }
}

// MARK: - codeg delegations

/// Who a codeg delegation (`delegate_to_agent`) runs as and what it was asked:
/// the payload of `delegation_started`, and of the snapshot's
/// `active_delegations` rows (Rust `ActiveDelegationState`) — the same fields.
/// `delegation_completed` carries the ids and agent but no task.
struct DelegationInfo: Hashable, Sendable {
    var parentToolUseId: String
    var childConnectionId: String
    var childConversationId: Int
    var agentType: AgentType
    var taskPreview: String?
    var taskId: String?
    var assistantId: Int?
    var assistantName: String?
}

extension DelegationInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case parentToolUseId, childConnectionId, childConversationId, agentType
        case taskPreview, taskId, assistantId, assistantName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        parentToolUseId = string(.parentToolUseId) ?? ""
        childConnectionId = string(.childConnectionId) ?? ""
        childConversationId = ((try? c.decodeIfPresent(Int.self, forKey: .childConversationId)) ?? nil) ?? 0
        agentType = ((try? c.decodeIfPresent(AgentType.self, forKey: .agentType)) ?? nil) ?? .other(wire: "")
        // `""` is the backend's default for an older row — no task, not an empty one.
        taskPreview = string(.taskPreview).flatMap { $0.isEmpty ? nil : $0 }
        taskId = string(.taskId).flatMap { $0.isEmpty ? nil : $0 }
        assistantId = (try? c.decodeIfPresent(Int.self, forKey: .assistantId)) ?? nil
        assistantName = string(.assistantName)
    }
}

/// A delegation as this client knows it (web `DelegationBinding`), keyed by
/// the parent's tool call. Bindings are kept after they finish: the running
/// list asks the parent's `delegated_children` WHICH still run, and a binding
/// only says who and what.
struct DelegationBinding: Hashable, Sendable {
    enum Status: Hashable, Sendable { case running, ok, err }

    var info: DelegationInfo
    var status: Status
    var errorCode: String?

    var parentToolUseId: String { info.parentToolUseId }
    var childConnectionId: String { info.childConnectionId }
}

// MARK: - The running list (web `src/lib/live-runs.ts`)

/// What a connection has running right now beyond the turn itself — the list
/// behind the composer's "N running" chip. Three kinds, each from the one
/// source that can say it is still alive:
///
/// - **Background tasks** — the AIR async-task table (``AsyncTasks/live(_:)``).
///   The adapter reports their terminal edge, and can stop them.
/// - **Sub-agents** — the BACKGROUND ones: a background launch returns at once
///   and works on after its turn, and only its producer's outstanding set
///   (kind `agent`) knows it is still out. Background shells are left out: the
///   task table lists them, with a stop. (The web also lists the streaming
///   reply's unsettled foreground sub-agents; on iOS those are already in the
///   live timeline right above, so they are not repeated here.)
/// - **Delegations** — codeg's `delegate_to_agent` children still running, per
///   the parent's `delegated_children`; a binding supplies who and what. A
///   child whose binding has finished is on its way out and is not listed; one
///   with no binding (its call never got a card) is listed bare.
struct LiveRuns: Equatable, Sendable {
    /// One of the agent's own background sub-agents.
    struct SubAgentRun: Hashable, Sendable, Identifiable {
        /// Stable list key.
        var key: String
        var toolUseId: String?
        /// The producer's description of it — the row's title.
        var description: String?
        /// When it started, Unix ms; nil when the producer did not say.
        var startedAtMs: Int64?

        var id: String { key }
    }

    /// One codeg delegation still running.
    struct DelegationRun: Hashable, Sendable, Identifiable {
        var childConnectionId: String
        /// nil when no binding names this child.
        var binding: DelegationBinding?

        var id: String { childConnectionId }
    }

    var tasks: [AsyncTaskRecord]
    var subagents: [SubAgentRun]
    var delegations: [DelegationRun]
    /// Rows in all three — what the chip says.
    var count: Int

    static let empty = LiveRuns(tasks: [], subagents: [], delegations: [], count: 0)

    static func collect(
        asyncTasks: [AsyncTaskRecord],
        backgroundTasks: [BackgroundOutstandingTask],
        delegatedChildren: [String],
        delegationBindings: [DelegationBinding]
    ) -> LiveRuns {
        let tasks = AsyncTasks.live(asyncTasks)

        var subagents: [SubAgentRun] = []
        var seenCalls = Set<String>()
        for task in backgroundTasks where task.kind == "agent" {
            let callId = task.toolUseId.flatMap { $0.isEmpty ? nil : $0 }
            // The same launch named twice (a resume re-announces it).
            if let callId {
                if seenCalls.contains(callId) { continue }
                seenCalls.insert(callId)
            }
            subagents.append(SubAgentRun(
                key: "bg:\(task.taskId)",
                toolUseId: callId,
                description: task.description,
                startedAtMs: task.startedAtMs > 0 ? task.startedAtMs : nil))
        }

        // A child can be bound more than once (a resume re-binds it); the
        // running binding is the one that speaks for it.
        var bindingByChild: [String: DelegationBinding] = [:]
        for binding in delegationBindings {
            if bindingByChild[binding.childConnectionId] == nil || binding.status == .running {
                bindingByChild[binding.childConnectionId] = binding
            }
        }
        var delegations: [DelegationRun] = []
        var seenChildren = Set<String>()
        for child in delegatedChildren {
            if seenChildren.contains(child) { continue }
            seenChildren.insert(child)
            let binding = bindingByChild[child]
            // Its completion is already in: it leaves with the backend's next word.
            if let binding, binding.status != .running { continue }
            delegations.append(DelegationRun(childConnectionId: child, binding: binding))
        }

        return LiveRuns(
            tasks: tasks,
            subagents: subagents,
            delegations: delegations,
            count: tasks.count + subagents.count + delegations.count)
    }

    /// `1.2K`, `3.5M`, `512` (web `formatTokenCount`).
    static func formatTokenCount(_ n: Int) -> String {
        func trimmed(_ value: Double) -> String {
            let fixed = String(format: "%.1f", value)
            return fixed.hasSuffix(".0") ? String(fixed.dropLast(2)) : fixed
        }
        if n >= 1_000_000 { return trimmed(Double(n) / 1_000_000) + "M" }
        if n >= 1_000 { return trimmed(Double(n) / 1_000) + "K" }
        return String(n)
    }
}

// MARK: - Row text

/// The running list's derived wording, kept beside the logic it reads.
enum LiveRunsText {
    /// What started a turn the agent ran on its own, in the user's language;
    /// nil when the adapter could not tell.
    static func turnCause(_ description: String) -> String? {
        switch AsyncTasks.autonomousTurnCause(description) {
        case .unknown:
            return nil
        case .scheduledWakeup(let at):
            guard let at else { return String(localized: "Scheduled wakeup") }
            return String(localized: "Scheduled wakeup for \(at.formatted(date: .omitted, time: .shortened))")
        case .scheduledTask:
            return String(localized: "Scheduled task")
        case .text(let text):
            return text
        }
    }

    /// `1h 2m 3s` / `3m 5s` / `5s` since a Unix-ms instant, localized.
    static func elapsed(since startedAtMs: Int64, now: Date) -> String {
        let seconds = max(0, Int((now.timeIntervalSince1970 * 1000 - Double(startedAtMs)) / 1000))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

// MARK: - The predicted next prompt

/// When the composer offers the agent's predicted next prompt (web
/// `offeredSuggestion` in `message-input.tsx`): only where sending it could
/// follow — never mid-turn (a send then queues or steers), never over a draft,
/// never behind messages already waiting their turn.
enum PromptSuggestionGate {
    static func offered(
        _ suggestion: String?,
        draft: String,
        hasAttachments: Bool,
        inFlight: Bool,
        steering: Bool,
        queueEmpty: Bool
    ) -> String? {
        guard draft.isEmpty, !hasAttachments, !inFlight, !steering, queueEmpty else { return nil }
        return normalized(suggestion)
    }

    /// The wire's text, trimmed; blank means none (web `e.text?.trim() || null`).
    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Snapshot fields

/// The live-runs and prompt-suggestion state a connection snapshot carries.
/// Every field is omitted on the wire when empty, so each decodes on its own
/// with `try?` — a shape surprise in one can't take the others (or the
/// snapshot carrying them) down.
struct ConnectionRunsSnapshot: Hashable, Sendable {
    var asyncTasks: [AsyncTaskRecord] = []
    var backgroundOutstandingTasks: [BackgroundOutstandingTask] = []
    var delegatedChildren: [String] = []
    var activeDelegations: [DelegationInfo] = []
    var promptSuggestion: String?
    /// Claude Code's Remote Control while it is on; absent when off.
    var remoteControl: RemoteControlInfo?
    /// The running agent is on its launch-time settings after a later save,
    /// and which settings drifted. Absent on servers that predate it: not stale.
    var configStale = false
    var configStaleKind: ConfigStaleKind?
    /// The goal-control actions the connection's adapter offers (`pause`,
    /// `clear`, …; see ``GoalActions/decode(_:)``). Nil: not known yet.
    var goalActions: [String]? = GoalActions.legacy

    static let empty = ConnectionRunsSnapshot()
}

/// The goal-control vocabulary a connection's adapter advertises (snapshot
/// `goal_actions`, web `useAdvertisedGoalActions`). Three ways on the wire: a
/// list is known; `null` means `initialize` hasn't answered yet — offer
/// nothing, and read again; absent is a server too old to say, which offers
/// codex's legacy pair. Offering a wrong one is worse than none: claude's
/// goal extension has no "pause".
enum GoalActions {
    static let legacy = ["pause", "clear"]

    private struct Probe: Decodable {
        let actions: [String]?
        private enum CodingKeys: String, CodingKey { case goalActions }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if !c.contains(.goalActions) {
                actions = GoalActions.legacy
            } else if (try? c.decodeNil(forKey: .goalActions)) == true {
                actions = nil
            } else {
                actions = ((try? c.decode([AnyJSON].self, forKey: .goalActions)) ?? []).compactMap(\.string)
            }
        }
    }

    /// The vocabulary a snapshot object carries.
    static func decode(_ decoder: Decoder) -> [String]? {
        (try? Probe(from: decoder))?.actions ?? nil
    }

    /// The vocabulary in a snapshot response body.
    static func decode(_ data: Data) -> [String]? {
        (try? CodegJSON.decoder.decode(Probe.self, from: data))?.actions ?? nil
    }
}

extension ConnectionRunsSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case asyncTasks, backgroundOutstandingTasks, delegatedChildren, activeDelegations, promptSuggestion
        case remoteControl, configStale, configStaleKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asyncTasks = ((try? c.decodeIfPresent([AsyncTaskRecord].self, forKey: .asyncTasks)) ?? nil) ?? []
        backgroundOutstandingTasks = ((try? c.decodeIfPresent(
            [BackgroundOutstandingTask].self, forKey: .backgroundOutstandingTasks)) ?? nil) ?? []
        delegatedChildren = ((try? c.decodeIfPresent([String].self, forKey: .delegatedChildren)) ?? nil) ?? []
        activeDelegations = ((try? c.decodeIfPresent([DelegationInfo].self, forKey: .activeDelegations)) ?? nil) ?? []
        promptSuggestion = (try? c.decodeIfPresent(String.self, forKey: .promptSuggestion)) ?? nil
        remoteControl = (try? c.decodeIfPresent(RemoteControlInfo.self, forKey: .remoteControl)) ?? nil
        configStale = ((try? c.decodeIfPresent(Bool.self, forKey: .configStale)) ?? nil) ?? false
        configStaleKind = ConfigStaleKind(wire: (try? c.decodeIfPresent(String.self, forKey: .configStaleKind)) ?? nil)
        goalActions = GoalActions.decode(decoder)
    }

    /// Decoded from the snapshot object itself, never throwing.
    static func lenient(from decoder: Decoder) -> ConnectionRunsSnapshot {
        (try? ConnectionRunsSnapshot(from: decoder)) ?? .empty
    }
}
