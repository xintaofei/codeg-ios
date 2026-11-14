import Foundation

// MARK: - Wire types

/// Cumulative cost of one async task, as the adapter last reported it (Rust
/// `AsyncTaskUsage`). All three fields are required upstream — the adapter
/// drops a partial object rather than publishing one — so it is present whole
/// or absent.
struct AsyncTaskUsage: Hashable, Sendable {
    var totalTokens: Int
    var toolUses: Int
    var durationMs: Int
}

extension AsyncTaskUsage: Decodable {
    private enum CodingKeys: String, CodingKey { case totalTokens, toolUses, durationMs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = ((try? c.decodeIfPresent(Int.self, forKey: .totalTokens)) ?? nil) ?? 0
        toolUses = ((try? c.decodeIfPresent(Int.self, forKey: .toolUses)) ?? nil) ?? 0
        durationMs = ((try? c.decodeIfPresent(Int.self, forKey: .durationMs)) ?? nil) ?? 0
    }
}

/// One JetBrains AIR async task — an agent's non-agent background work
/// (Claude's background shells, workflows, monitors and the turns it starts on
/// its own; codex's background terminals; Grok's workflows). The MERGED row
/// (Rust `AsyncTaskRecord`), as the snapshot's `async_tasks` table carries it;
/// live `async_task` events revise it with partial deltas (``AsyncTaskDelta``).
///
/// `taskType` and `state` stay plain strings: an unmapped future type renders
/// as itself, and any state outside the terminal three counts as still live.
struct AsyncTaskRecord: Hashable, Sendable {
    var taskId: String
    var name: String
    var taskType: String
    var description: String
    var showInTranscript: Bool
    var canStop: Bool
    var state: String
    var summary: String?
    var lastToolName: String?
    var usage: AsyncTaskUsage?
    var outputFilePath: String?
    var toolCallId: String?
    /// A multi-step task's current phase (a Grok workflow's). Empty = none.
    var phase: String?
    /// The child agent it is running right now (Grok). Empty = none.
    var currentAgent: String?
}

// Decoding lives in an extension so the memberwise initializer survives.
extension AsyncTaskRecord: Decodable {
    private enum CodingKeys: String, CodingKey {
        case taskId, name, taskType, description, showInTranscript, canStop, state
        case summary, lastToolName, usage, outputFilePath, toolCallId, phase, currentAgent
    }

    /// Lenient field by field: one odd row must not fail the snapshot it rides.
    /// A row without an id decodes with an empty one, which every merge skips.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func bool(_ key: CodingKeys) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        taskId = string(.taskId) ?? ""
        name = string(.name) ?? "Background task"
        taskType = string(.taskType) ?? "task"
        description = string(.description) ?? ""
        showInTranscript = bool(.showInTranscript) ?? true
        canStop = bool(.canStop) ?? false
        state = string(.state) ?? "running"
        summary = string(.summary)
        lastToolName = string(.lastToolName)
        usage = (try? c.decodeIfPresent(AsyncTaskUsage.self, forKey: .usage)) ?? nil
        outputFilePath = string(.outputFilePath)
        toolCallId = string(.toolCallId)
        phase = string(.phase)
        currentAgent = string(.currentAgent)
    }
}

/// One `async_task` delta as it arrived (Rust `AsyncTaskDelta`): `taskId` says
/// which row, `spawned` whether this frame may CREATE one, and every other
/// field is an optional revision — ABSENT MEANS UNCHANGED.
struct AsyncTaskDelta: Hashable, Sendable {
    var taskId: String
    var spawned: Bool
    var name: String?
    var taskType: String?
    var description: String?
    var showInTranscript: Bool?
    var canStop: Bool?
    var state: String?
    var summary: String?
    var lastToolName: String?
    var usage: AsyncTaskUsage?
    var outputFilePath: String?
    var toolCallId: String?
    var phase: String?
    var currentAgent: String?

    init(taskId: String, spawned: Bool, name: String? = nil, taskType: String? = nil,
         description: String? = nil, showInTranscript: Bool? = nil, canStop: Bool? = nil,
         state: String? = nil, summary: String? = nil, lastToolName: String? = nil,
         usage: AsyncTaskUsage? = nil, outputFilePath: String? = nil, toolCallId: String? = nil,
         phase: String? = nil, currentAgent: String? = nil) {
        self.taskId = taskId
        self.spawned = spawned
        self.name = name
        self.taskType = taskType
        self.description = description
        self.showInTranscript = showInTranscript
        self.canStop = canStop
        self.state = state
        self.summary = summary
        self.lastToolName = lastToolName
        self.usage = usage
        self.outputFilePath = outputFilePath
        self.toolCallId = toolCallId
        self.phase = phase
        self.currentAgent = currentAgent
    }
}

extension AsyncTaskDelta: Decodable {
    private enum CodingKeys: String, CodingKey {
        case taskId, spawned, name, taskType, description, showInTranscript, canStop, state
        case summary, lastToolName, usage, outputFilePath, toolCallId, phase, currentAgent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func bool(_ key: CodingKeys) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        self.init(
            taskId: string(.taskId) ?? "",
            spawned: bool(.spawned) ?? false,
            name: string(.name),
            taskType: string(.taskType),
            description: string(.description),
            showInTranscript: bool(.showInTranscript),
            canStop: bool(.canStop),
            state: string(.state),
            summary: string(.summary),
            lastToolName: string(.lastToolName),
            usage: (try? c.decodeIfPresent(AsyncTaskUsage.self, forKey: .usage)) ?? nil,
            outputFilePath: string(.outputFilePath),
            toolCallId: string(.toolCallId),
            phase: string(.phase),
            currentAgent: string(.currentAgent))
    }
}

// MARK: - Merge rules (web `src/lib/async-tasks.ts`)

/// The client half of the AIR async-task projection, matching the backend's
/// `SessionState::apply_event`:
///
/// - only a `spawned` delta may CREATE a row. A delta naming an unknown task
///   means its announcement — the one frame carrying name, type and stop
///   affordance — was missed, and a placeholder row is worse than none.
/// - every other field is optional and absent means unchanged. A progress tick
///   carries only what moved; treating absence as "clear it" would blank a
///   task's name on its first update. (Grok restates its whole run on every
///   frame and clears with `""` — present, so it is applied.)
///
/// Rows are RETAINED after they settle: the adapter keeps revising a finished
/// task (a late output path, a best-effort `stopped` corrected into the real
/// `completed`), and an evicted row would be re-created by its own correction —
/// nameless, since only `spawned` carries identity. What to SHOW is
/// ``live(_:)``'s business.
enum AsyncTasks {
    /// States the adapter never revises away from.
    static let terminalStates: Set<String> = ["completed", "failed", "stopped"]

    static func isTerminal(_ task: AsyncTaskRecord) -> Bool {
        terminalStates.contains(task.state)
    }

    /// The row a `spawned` delta creates. The defaults exist because the wire
    /// fields are individually optional, not because a half-announced task is
    /// expected.
    static func record(from delta: AsyncTaskDelta) -> AsyncTaskRecord {
        AsyncTaskRecord(
            taskId: delta.taskId,
            name: delta.name ?? "Background task",
            taskType: delta.taskType ?? "task",
            description: delta.description ?? "",
            showInTranscript: delta.showInTranscript ?? true,
            canStop: delta.canStop ?? false,
            state: delta.state ?? "running",
            summary: delta.summary,
            lastToolName: delta.lastToolName,
            usage: delta.usage,
            outputFilePath: delta.outputFilePath,
            toolCallId: delta.toolCallId,
            phase: delta.phase,
            currentAgent: delta.currentAgent)
    }

    /// A delta's PRESENT fields applied onto a stored row.
    static func applying(_ delta: AsyncTaskDelta, to stored: AsyncTaskRecord) -> AsyncTaskRecord {
        var next = stored
        if let v = delta.name { next.name = v }
        if let v = delta.taskType { next.taskType = v }
        if let v = delta.description { next.description = v }
        if let v = delta.showInTranscript { next.showInTranscript = v }
        if let v = delta.canStop { next.canStop = v }
        if let v = delta.state { next.state = v }
        if let v = delta.summary { next.summary = v }
        if let v = delta.lastToolName { next.lastToolName = v }
        if let v = delta.usage { next.usage = v }
        if let v = delta.outputFilePath { next.outputFilePath = v }
        if let v = delta.toolCallId { next.toolCallId = v }
        if let v = delta.phase { next.phase = v }
        if let v = delta.currentAgent { next.currentAgent = v }
        return next
    }

    /// Merge one live delta into the table. Unchanged (`==`) when it names a
    /// task that was never announced, or carries no id.
    static func upsert(_ current: [AsyncTaskRecord], _ delta: AsyncTaskDelta) -> [AsyncTaskRecord] {
        guard !delta.taskId.isEmpty else { return current }
        guard let index = current.firstIndex(where: { $0.taskId == delta.taskId }) else {
            guard delta.spawned else { return current }
            return current + [record(from: delta)]
        }
        var next = current
        next[index] = applying(delta, to: current[index])
        return next
    }

    /// Seed from a snapshot's merged table. Whole rows, not deltas — the backend
    /// already merged them — so this REPLACES by id and appends unknown ids.
    ///
    /// ONLY for a snapshot newer than everything this client has applied: the
    /// rows carry no revision, so "replace by id" is sound only while the
    /// snapshot is known to be the fresher of the two. Otherwise use
    /// ``adoptUnknown(_:_:)``.
    static func merge(_ current: [AsyncTaskRecord], _ incoming: [AsyncTaskRecord]?) -> [AsyncTaskRecord] {
        guard let incoming, !incoming.isEmpty else { return current }
        var next = current
        for record in incoming where !record.taskId.isEmpty {
            if let index = next.firstIndex(where: { $0.taskId == record.taskId }) {
                next[index] = record
            } else {
                next.append(record)
            }
        }
        return next
    }

    /// Fold a STALE snapshot in without letting it overwrite anything.
    ///
    /// A snapshot the client has already passed was taken BEFORE deltas it
    /// applied, so its rows can be older — replacing by id would walk a task
    /// the client saw finish back to `running`, and the terminal event is not
    /// replayed to correct it. Adding is still safe, and still worth it: a
    /// client that attached mid-episode has no other way to learn of work
    /// already running.
    static func adoptUnknown(_ current: [AsyncTaskRecord], _ incoming: [AsyncTaskRecord]?) -> [AsyncTaskRecord] {
        guard let incoming, !incoming.isEmpty else { return current }
        var next = current
        for record in incoming where !record.taskId.isEmpty {
            if next.contains(where: { $0.taskId == record.taskId }) { continue }
            next.append(record)
        }
        return next
    }

    /// What the running list shows: tasks still running or paused. A settled
    /// task leaves at once — its outcome belongs to the transcript, and a list
    /// of finished jobs would grow all session.
    static func live(_ tasks: [AsyncTaskRecord]) -> [AsyncTaskRecord] {
        tasks.filter { !isTerminal($0) }
    }

    // MARK: Autonomous turns

    /// The task type of a turn the agent started on its own, with no prompt
    /// open — Claude Code's answer to a finished background task, or a
    /// scheduled wakeup. claude-agent-acp 0.97.0 publishes each one as an async
    /// task (`autonomous-turn-<uuid>`, "Claude is working", stoppable) because
    /// ACP v1 has no other sign that the agent works again after the prompt's
    /// `end_turn`. It ends `completed`/`failed` with the turn; stopping it
    /// interrupts the turn.
    static let autonomousTurnTaskType = "turn"

    private static let noCauseSentence = "Claude Code started a turn without a prompt."
    private static let wakeupSentence = "A scheduled wakeup fired."
    private static let wakeupAtPrefix = "A scheduled wakeup fired (set for "
    private static let wakeupAtSuffix = ")."
    private static let scheduledTaskSentence = "A scheduled task fired."

    /// What started an autonomous turn, read from its task's `description`.
    /// claude-agent-acp 0.97.0's fixed sentences are matched whole, so a
    /// reworded one is shown as Claude Code's own text rather than misread.
    static func autonomousTurnCause(_ description: String) -> AutonomousTurnCause {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == noCauseSentence { return .unknown }
        if text == wakeupSentence { return .scheduledWakeup(at: nil) }
        if text == scheduledTaskSentence { return .scheduledTask }
        // web: /^A scheduled wakeup fired \(set for (.+)\)\.$/ — `.` stops at a
        // line break and needs at least one character.
        if text.hasPrefix(wakeupAtPrefix), text.hasSuffix(wakeupAtSuffix),
           text.count > wakeupAtPrefix.count + wakeupAtSuffix.count {
            let body = text.dropFirst(wakeupAtPrefix.count).dropLast(wakeupAtSuffix.count)
            if !body.contains(where: \.isNewline) {
                return .scheduledWakeup(at: ISO8601.parse(String(body)))
            }
        }
        return .text(text)
    }
}

/// What started an autonomous turn (web `AutonomousTurnCause`).
enum AutonomousTurnCause: Equatable, Sendable {
    /// The adapter could not tell.
    case unknown
    /// A `ScheduleWakeup` (dynamic `/loop`) wakeup; `at` is the time it was set
    /// for, when the adapter says and it parses.
    case scheduledWakeup(at: Date?)
    /// Another scheduled task, such as a cron job.
    case scheduledTask
    /// Claude Code's own words — e.g. the summary of the task notification
    /// that started the turn.
    case text(String)
}
