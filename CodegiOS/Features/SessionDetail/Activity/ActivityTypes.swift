import Foundation

// The activity timeline's view model — port of the web's
// `src/lib/activity/types.ts` (codeg 0.44). A reply's parts become STEPS (one
// per tool call, thought, note, …), consecutive explore / command calls fold
// into GROUPS, and a SUMMARY counts what the reply did for its header.
//
// Where the web carries its adapter's parts, the iOS steps carry the iOS
// render inputs: a `ToolCallVM` per call, and for prose that is still
// streaming the `LiveTextRun` itself — never a snapshot of its text, which the
// leaf view must read so that streaming keeps updating.

/// What a tool call was, as far as the timeline is concerned. Decides the
/// row's icon, its layout, and which group (if any) it can join.
enum ToolStepKind: String, Sendable, Hashable {
    // Exploration: reading the workspace or the web. Consecutive ones fold
    // into one "Explored" row.
    case read, search, glob, list, fetch
    case webSearch = "web-search"
    case memory
    // Execution. Consecutive ones fold into one "Ran N commands" row.
    case command
    case shellSession = "shell-session"
    case script
    /// A watch left running in the background (Claude Code's `Monitor`):
    /// drawn like a command, never folded with them.
    case monitor
    /// A sandbox's request to reach a host — a question, not a call that runs.
    case network
    case edit
    case mcp, generic, skill, todo
    // Calls with lifecycles or interactive records of their own.
    case agent
    case collabAgent = "collab-agent"
    case delegation
    case delegationStatus = "delegation-status"
    case delegationCancel = "delegation-cancel"
    case delegationResume = "delegation-resume"
    case goal
    case planMode = "plan-mode"
    case question, feedback, workbench, compaction, completion

    /// The group family a call of this kind can join, if any.
    var family: ActivityGroupKind? {
        switch self {
        case .read, .search, .glob, .list, .fetch, .webSearch, .memory: return .explore
        case .command, .shellSession, .script: return .command
        default: return nil
        }
    }
}

/// The two runs consecutive calls fold into.
enum ActivityGroupKind: String, Sendable, Hashable {
    case explore, command
}

/// One status vocabulary for every step, after Zed's seven tool-call states.
/// Visually `pending` draws like `running` and `rejected` like `failed` (with
/// its own wording); `cancelled` is the "interrupted" state.
enum StepStatus: String, Sendable, Hashable {
    case pending, running, awaiting, succeeded, failed, rejected, cancelled

    var isLive: Bool { self == .pending || self == .running }
    var isFailure: Bool { self == .failed || self == .rejected }
}

/// The figure in a row's right-hand column.
enum ToolMetric: Equatable, Hashable, Sendable {
    case lines(Int)
    case matches(count: Int, files: Int)
    case files(Int)
    case results(Int)
    case noMatch
    case diff(additions: Int, deletions: Int)
}

/// Argument details a row names beside its target (localized there).
enum ToolNote: Equatable, Hashable, Sendable {
    case allowLarge
    case pages(String)
    case offset(Int)
}

/// What a command row shows of its command.
struct CommandInfo: Equatable, Hashable, Sendable {
    /// Set for codex's `wait` / `write_stdin`, which address a running shell.
    struct Session: Equatable, Hashable, Sendable {
        enum Verb: String, Sendable { case wait, terminate, stdin }
        var verb: Verb
        var sessionId: String?
        var stdin: String?
    }
    /// The command with shell wrappers removed, all lines.
    var display: String
    var lineCount: Int
    var heredoc: HeredocCommand?
    /// The agent's own one-line description of the command (Claude Code).
    var description: String?
    var session: Session?
    /// Wall time the agent reported, in milliseconds.
    var durationMs: Int?
    /// The background shell session the command's own output announced
    /// (`SESSION_ID=…`), which later `wait` calls address by id.
    var announcedSession: String?
    /// A monitor watching a WebSocket rather than a command's output:
    /// `display` is then the socket's URL.
    var websocket = false
}

/// What a call acted on.
struct ToolTarget: Equatable, Hashable, Sendable {
    /// What the row shows.
    var text: String
    /// The untruncated value, when `text` was shortened.
    var full: String?
    /// A file path the row can open.
    var path: String?
}

/// Everything a row needs to draw one tool call (web `ToolDescriptor`).
struct ToolDescriptor: Equatable, Sendable {
    var kind: ToolStepKind
    /// Normalized tool name.
    var toolName: String
    var status: StepStatus
    var target: ToolTarget?
    /// Muted text after the target.
    var detail: String?
    var notes: [ToolNote] = []
    var metric: ToolMetric?
    /// A command's non-zero exit, when the result reported one: a failure's,
    /// or one that answers the command's question (`exitMeaning`).
    var exit: CommandExit?
    var exitMeaning: ExitMeaning?
    var command: CommandInfo?
    var files: [EditFileChange]?
    var mcp: McpIdentity?
    /// A command whose process was moved to the background, or a monitor's
    /// background task, by the id the agent gave it.
    var background: Background?
    var approval: ToolApproval?

    struct Background: Equatable, Hashable, Sendable {
        var taskId: String?
    }
}

/// Prose a thought or note carries: settled text, or the run still streaming.
enum ActivityText {
    case settled(String)
    /// `streaming`: this run is the one still growing (it draws the caret).
    case live(LiveTextRun, streaming: Bool)
}

/// Answer-shaped parts that landed between steps — prose, a proposed plan, a
/// turn error. They stay where they were written, as notes.
enum ActivityNote {
    case text(ActivityText)
    /// A codex Plan-mode `<proposed_plan>` block (settled prose only).
    case proposedPlan(markdown: String, streaming: Bool)
    case turnError(String)
}

/// One step of a reply's process (web `ActivityStep`).
enum ActivityStep {
    case tool(ActivityToolStep)
    /// The agent's reasoning between its calls. `title` is computed by the
    /// row from the text (it changes as a live thought streams).
    case thought(key: String, text: ActivityText, streaming: Bool)
    case note(key: String, ActivityNote)
    case image(key: String, ImageData, caption: String?)
    /// A plan checklist (`RenderPart.plan`). `id` is the call it is recorded
    /// as, which its row is keyed by — the same live and handed off.
    case plan(key: String, id: String, entries: [PlanEntry], streaming: Bool)
    /// A run of `get_delegation_status` polls, drawn as one row.
    case delegationPolls(key: String, polls: [ToolCallVM], status: StepStatus)
    /// A run of background-task polls (Claude Code's `TaskOutput` /
    /// `TaskStop`, Grok's and CodeBuddy's), drawn as one row per task.
    case backgroundTasks(BackgroundTasksStep)
    /// A run of TaskCreate/TaskUpdate/… calls — iOS's evolving checklist,
    /// which the web draws as plain todo rows. Kept: see the sync plan §2.4.
    case taskList(key: String, ops: [ToolCallVM])
    /// A context-compaction boundary (`_meta.contextCompaction`, either shape).
    case compaction(key: String, CompactionInfo)
    case unsupported(key: String, type: String)
    /// A Codex `/goal` run, drawn as one row whose body is its own timeline.
    case goal(ActivityGoalStep)

    var key: String {
        switch self {
        case .tool(let step): return step.key
        case .backgroundTasks(let step): return step.key
        case .thought(let key, _, _), .note(let key, _), .image(let key, _, _),
             .plan(let key, _, _, _), .delegationPolls(let key, _, _), .taskList(let key, _),
             .compaction(let key, _), .unsupported(let key, _):
            return key
        case .goal(let step): return step.key
        }
    }

    var toolStep: ActivityToolStep? {
        if case .tool(let step) = self { return step }
        return nil
    }
}

/// A tool call's step.
struct ActivityToolStep {
    var key: String
    var call: ToolCallVM
    var tool: ToolDescriptor
    /// A delegation's `get_delegation_status` polls about its task that came
    /// after it — drawn as rows of their own, but the newest says how the
    /// delegation stands now.
    var laterPolls: [ToolCallVM]?
}

/// A goal run's step (web `{ type: "goal", part, model }`).
struct ActivityGoalStep {
    var key: String
    var run: GoalRunPart
    /// The run's own steps, built like a reply's — but with no answer slot:
    /// whatever prose the run holds (the answer streaming inside a live run,
    /// notes before its closing `update_goal`) stays a step, or it would
    /// never be drawn.
    var model: ReplyActivity
    /// What the goal calls say about the goal.
    var facts: ActivityGoal.Facts

    init(key: String, run: GoalRunPart, model: ReplyActivity) {
        self.key = key
        self.run = run
        self.model = model
        self.facts = ActivityGoal.facts(start: run.start, end: run.end)
    }

    var isError: Bool { ActivityGoal.isError(start: run.start, end: run.end) }
}

/// A run of background-task polls (web `background-tasks` step).
struct BackgroundTasksStep {
    /// `bg:<first poll id>`.
    let key: String
    let polls: [ToolCallVM]
    let status: StepStatus
    /// The commands that started these tasks, by task id — earlier steps of
    /// the same reply whose output announced the launch.
    let launches: [String: BackgroundLaunch]
    /// One row per task (`BackgroundTask.buildRows`). Built once with the
    /// step: the header counts, the rail and the rows all read it.
    let rows: [BackgroundTask.Row]

    /// `status`: the lane's own (`BackgroundTask.status`) unless given.
    init(key: String, polls: [ToolCallVM], status: StepStatus? = nil,
         launches: [String: BackgroundLaunch] = [:]) {
        let rows = BackgroundTask.buildRows(polls)
        self.key = key
        self.polls = polls
        self.rows = rows
        self.status = status ?? BackgroundTask.status(rows)
        self.launches = launches
    }
}

/// A row of the timeline: one step, or a folded run of explore / command calls.
enum ActivityItem {
    case step(ActivityStep)
    /// The run's calls in order. Keyed by its first member, so a run that
    /// grows keeps its key — and with it the reader's open/closed choice.
    case group(key: String, kind: ActivityGroupKind, steps: [ActivityToolStep], status: StepStatus)

    var key: String {
        switch self {
        case .step(let step): return step.key
        case .group(let key, _, _, _): return key
        }
    }
}

struct ActivityCounts: Equatable, Sendable {
    var commands = 0
    var editedFiles = 0
    var agents = 0
    var mcp = 0
    var web = 0
    var readFiles = 0
    var searches = 0
}

/// What the reply's header says.
struct ActivitySummary: Equatable, Sendable {
    /// Tool-like steps: calls, sub-agents, delegations, background tasks (one
    /// each, however often polled). Thoughts, notes, plans and compactions do
    /// not count.
    var steps = 0
    var counts = ActivityCounts()
    var failed = 0
    /// Failures no later step redid successfully.
    var unrecovered = 0
    var interrupted = 0
    var running = false
    /// Key of the first unrecovered failure, for "jump to failure".
    var firstUnrecoveredKey: String?
    /// Keys of failed steps a later step recovered.
    var recoveredKeys: Set<String> = []
}

/// The activity model of one reply (web `ActivityModel`; that name is taken
/// by the Activity tab).
struct ReplyActivity {
    /// Every process step, in order.
    var steps: [ActivityStep]
    /// The steps with explore / command runs folded into groups.
    var items: [ActivityItem]
    /// The reply's trailing answer — rendered after the timeline, unfolded.
    var answer: [RenderPart]
    var summary: ActivitySummary

    /// No steps at all — a goal call's row outside any run.
    static var empty: ReplyActivity {
        ReplyActivity(steps: [], items: [], answer: [], summary: ActivitySummary())
    }
}
