import Foundation

/// A reply's render parts → its activity model (steps, grouped rows, trailing
/// answer, header summary) — port of the web's
/// `src/lib/activity/build-activity.ts` (codeg 0.44).
///
/// Runs on the parts `MessageRender` adapts for one reply, BEFORE its generic
/// tool grouping: delegation polls, background-task polls and task-checklist
/// runs arrive already gathered (they are lanes of their own), plain tool
/// calls arrive one by one and are grouped here, by kind.
///
/// Live prose is never read here. A `LiveTextRun` is referred to by its id —
/// reading its text would subscribe whoever builds the model to every streamed
/// token, which is exactly what the leaf views reading it exist to avoid.
@MainActor
enum BuildActivity {
    /// Build one reply's model.
    /// - Parameters:
    ///   - isStreaming: the reply is still being written.
    ///   - keepAnswer: keep closing prose as steps instead of splitting it off
    ///     as the answer — for a reply still being written, whose closing prose
    ///     is not known yet, and for a sub-agent's own timeline.
    ///
    /// What only the live connection knows — the call a permission request
    /// waits on, how answered ones went — is laid over the rows as they draw
    /// (``ActivityLive``), not built in, so a request never rebuilds a reply.
    static func build(_ parts: [RenderPart], isStreaming: Bool, keepAnswer: Bool = false) -> ReplyActivity {
        let (body, trailing) = keepAnswer ? (parts, []) : splitTrailingAnswer(parts)
        let anchor = replyAnchor(body)
        let steps = linkLaterDelegationPolls(collectSteps(body, isStreaming: isStreaming, anchor: anchor))
        let summary = ActivitySummarize.summarize(steps)
        let items = ActivityGroup.items(steps.filter { !isBlankInterruption($0) })
        return ReplyActivity(steps: steps, items: items, answer: trailing, summary: summary)
    }

    // MARK: - Answer split

    /// Parts that ARE the reply's answer rather than the process that produced
    /// it: prose, the codex Plan-mode document the user has to read, a
    /// generated image, the failure line. A plan CHECKLIST is process — the
    /// agent's bookkeeping of the work (web `isTurnAnswerPart`). Exhaustive on
    /// purpose, so a new part kind has to be classified here.
    static func isAnswerPart(_ part: RenderPart) -> Bool {
        switch part {
        case .text, .liveText, .proposedPlan, .image, .turnError:
            return true
        case .reasoning, .liveReasoning, .tool, .delegationStatusGroup, .backgroundTaskGroup, .taskGroup,
             .plan, .compaction, .unknown:
            return false
        case .goalRun:
            return false
        }
    }

    /// Split a reply at its last process part: everything after it is the
    /// answer, in order. Answer parts BEFORE a process part stay in the body —
    /// prose followed by more work is a mid-run note, not a wrap-up.
    static func splitTrailingAnswer(_ parts: [RenderPart]) -> (body: [RenderPart], trailing: [RenderPart]) {
        var end = parts.count
        while end > 0, isAnswerPart(parts[end - 1]) { end -= 1 }
        return (Array(parts[..<end]), Array(parts[end...]))
    }

    /// Does a reply's answer leave anything for the reader? Whitespace-only
    /// settled text is not an answer. (Live text is assumed visible: it is not
    /// read here.)
    static func hasVisibleAnswer(_ answer: [RenderPart]) -> Bool {
        answer.contains { part in
            if case .text(let t) = part { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }

    // MARK: - Keys

    private static let anchorTextLength = 32

    /// djb2 over UTF-16 code units, base 36 — only has to tell replies apart.
    static func hashText(_ text: String) -> String {
        var hash: Int32 = 5381
        for unit in text.utf16 { hash = (hash &<< 5) &+ hash &+ Int32(unit) }
        return String(UInt32(bitPattern: hash), radix: 36)
    }

    /// A stable name for the reply, prefixed onto the keys of steps that have no
    /// id of their own (thoughts, notes, plans), so a remembered open/closed
    /// choice stays with the right row. The opening settled prose names it when
    /// the reply starts with some; a live run its run id; otherwise the first
    /// tool call id (ids persist across the live → history hand-over).
    static func replyAnchor(_ parts: [RenderPart]) -> String {
        switch parts.first {
        case .text(let t)?, .reasoning(let t)?:
            if t.trimmingCharacters(in: .whitespacesAndNewlines).count >= anchorTextLength {
                return "h" + hashText(String(decoding: Array(t.utf16.prefix(anchorTextLength)), as: UTF16.self))
            }
        case .liveText(let run, _)?, .liveReasoning(let run, _)?:
            return "r" + run.id
        default:
            break
        }
        for part in parts {
            switch part {
            case .tool(let vm): return vm.id
            case .delegationStatusGroup(let polls), .backgroundTaskGroup(let polls), .taskGroup(let polls):
                if let first = polls.first { return first.id }
            case .goalRun(let run): return run.start.id
            default: continue
            }
        }
        // No call to name it by: hash what it opens with (the web hashes the
        // first part's JSON), so two such replies — a short thought before the
        // answer is the common one — do not share their rows' keys.
        guard let first = parts.first else { return "empty" }
        return "h" + hashText(String(decoding: Array(anchorSignature(first).utf16.prefix(200)), as: UTF16.self))
    }

    /// The first part's content, for `replyAnchor`'s fallback.
    private static func anchorSignature(_ part: RenderPart) -> String {
        switch part {
        case .text(let t): return "text:\(t)"
        case .reasoning(let t): return "reasoning:\(t)"
        case .turnError(let message): return "turn-error:\(message)"
        case .proposedPlan(let markdown, let streaming): return "proposed-plan:\(markdown):\(streaming)"
        case .image(let image, let caption):
            return "image:\(caption ?? ""):\(image.uri ?? ""):\(image.data.prefix(160))"
        case .compaction(let info):
            return "compaction:\(info.before.map(String.init) ?? ""):\(info.after.map(String.init) ?? "")"
        case .unknown(let type): return "unknown:\(type)"
        case .liveText(let run, _), .liveReasoning(let run, _): return "run:\(run.id)"
        case .tool(let vm): return "tool:\(vm.id)"
        case .delegationStatusGroup, .backgroundTaskGroup, .taskGroup: return "group"
        case .goalRun(let run): return "goal-run:\(run.start.id)"
        // By the call it is recorded as, not its entries: a live plan's are
        // revised as the reply goes on, and the anchor must not move with them.
        case .plan(let id, _, _): return "plan:\(id)"
        }
    }

    /// A step's identity within its own reply: its key without the reply's
    /// anchor. Within one reply the part's place is enough, and it does not
    /// change while the anchor text is still growing.
    static func rowIdentity(_ key: String) -> String {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, ["note", "thought", "plan", "image"].contains(String(parts[0])),
              let last = parts.last, Int(last) != nil else { return key }
        return "\(parts[0])@\(last)"
    }

    // MARK: - Steps

    private static func collectSteps(_ parts: [RenderPart], isStreaming: Bool, anchor: String) -> [ActivityStep] {
        var steps: [ActivityStep] = []
        for (index, part) in parts.enumerated() {
            let key = { (kind: String) in "\(kind):\(anchor):\(index)" }
            switch part {
            case .text(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    steps.append(.note(key: key("note"), .text(.settled(t))))
                }
            case .liveText(let run, let streaming):
                steps.append(.note(key: key("note"), .text(.live(run, streaming: streaming))))
            case .proposedPlan(let markdown, let streaming):
                steps.append(.note(key: key("note"), .proposedPlan(markdown: markdown, streaming: streaming)))
            case .turnError(let message):
                steps.append(.note(key: key("note"), .turnError(message)))
            case .reasoning(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    steps.append(.thought(key: key("thought"), text: .settled(t), streaming: false))
                }
            case .liveReasoning(let run, let streaming):
                steps.append(.thought(key: key("thought"), text: .live(run, streaming: streaming),
                                      streaming: isStreaming && streaming))
            case .tool(let vm):
                steps.append(.tool(toolStep(vm)))
            case .delegationStatusGroup(let polls):
                guard let first = polls.first else { continue }
                steps.append(.delegationPolls(key: "dpoll:\(first.id)", polls: polls,
                                              status: ActivityStatus.combine(polls.map { ActivityStatus.of($0) })))
            case .backgroundTaskGroup(let polls):
                guard let first = polls.first else { continue }
                steps.append(.backgroundTasks(BackgroundTasksStep(
                    key: "bg:\(first.id)", polls: polls, launches: launchesBefore(steps))))
            case .taskGroup(let ops):
                guard let first = ops.first else { continue }
                steps.append(.taskList(key: "tasks:\(first.id)", ops: ops))
            case .plan(let id, let entries, let streaming):
                steps.append(.plan(key: key("plan"), id: id, entries: entries, streaming: streaming))
            case .image(let image, let caption):
                steps.append(.image(key: key("image"), image, caption: caption))
            case .compaction(let info):
                steps.append(.compaction(key: key("compaction"), info))
            case .unknown(let type):
                steps.append(.unsupported(key: key("unsupported"), type: type))
            case .goalRun(let run):
                steps.append(.goal(goalStep(run)))
            }
        }
        return steps
    }

    private static func toolStep(_ vm: ToolCallVM) -> ActivityToolStep {
        ActivityToolStep(key: "tool:\(vm.id)", call: vm, tool: DescribeCache.describe(vm, awaiting: false))
    }

    /// A goal run's step: its parts built as a model of their own, streaming
    /// while the run is, with no answer split off (the goal row has no answer
    /// slot).
    static func goalStep(_ run: GoalRunPart) -> ActivityGoalStep {
        ActivityGoalStep(key: "goal:\(run.start.id)", run: run,
                         model: build(run.items, isStreaming: run.isRunning, keepAnswer: true))
    }

    /// A goal call outside any run — an `update_goal` whose run began in an
    /// earlier reply — drawn as the goal row too, with no steps of its own
    /// (web `GoalToolCallPart`). Working while the call itself is.
    static func loneGoalStep(_ step: ActivityToolStep) -> ActivityGoalStep {
        ActivityGoalStep(key: step.key,
                         run: GoalRunPart(start: step.call, end: nil, items: [],
                                          isRunning: GoalRuns.isRunningCall(step.call)),
                         model: .empty)
    }

    /// Background launches among the steps so far, by task id: a command (or
    /// a monitor) whose output said it went on in the background. A later
    /// launch of the same id wins.
    private static func launchesBefore(_ steps: [ActivityStep]) -> [String: BackgroundLaunch] {
        var launches: [String: BackgroundLaunch] = [:]
        for step in steps {
            guard let tool = step.toolStep, let taskId = tool.tool.background?.taskId, !taskId.isEmpty,
                  let command = tool.tool.command else { continue }
            launches[taskId] = BackgroundLaunch(stepKey: tool.key, command: command.display,
                                                description: command.description)
        }
        return launches
    }

    /// A call interrupted before it carried anything — no arguments, no output
    /// beyond the interruption marker. It says nothing a row could show, so it
    /// is left out of the rows (the header still counts it as interrupted).
    private static func isBlankInterruption(_ step: ActivityStep) -> Bool {
        guard let tool = step.toolStep, tool.tool.status == .cancelled else { return false }
        let input = tool.call.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return input.isEmpty || input == "{}" || input == "[]" || input == "null"
    }

    /// A delegation's status checks are rows of their own, yet the newest of
    /// them says how the delegation stands: hand the delegation step the polls
    /// about its task. A resume of the task is a delegation step too, and the
    /// checks after it go to it, not to the call before it.
    private static func linkLaterDelegationPolls(_ steps: [ActivityStep]) -> [ActivityStep] {
        var tasksCache: [String: Set<String?>] = [:]
        func tasks(_ key: String, _ polls: [ToolCallVM]) -> Set<String?> {
            if let cached = tasksCache[key] { return cached }
            let set = Set(DelegationModel.buildTaskRows(polls).map(\.taskId))
            tasksCache[key] = set
            return set
        }
        return steps.enumerated().map { index, step in
            guard var tool = step.toolStep,
                  tool.tool.kind == .delegation || tool.tool.kind == .delegationResume,
                  let taskId = ActivitySummarize.delegationTaskId(tool) else { return step }
            var later: [ToolCallVM] = []
            for next in steps[(index + 1)...] {
                if let nextTool = next.toolStep, nextTool.tool.kind == .delegationResume,
                   ActivitySummarize.delegationTaskId(nextTool) == taskId { break }
                if case .delegationPolls(let key, let polls, _) = next, tasks(key, polls).contains(taskId) {
                    later.append(contentsOf: polls)
                }
            }
            tool.laterPolls = later.isEmpty ? nil : later
            return .tool(tool)
        }
    }
}

/// Descriptors are the expensive half of a build (each one parses the call's
/// input and output), and the live tier rebuilds its model on every pass — so
/// they are cached by the call's raw content. Bounded: the replies on screen
/// and the ones just handed over to history.
@MainActor
enum DescribeCache {
    private struct Key: Hashable {
        let id: String
        let rawName: String
        /// The inferred name too: a live call's depends on its kind as well.
        let toolName: String
        let state: ToolCallState
        let input: String?
        let output: String?
        let isError: Bool
        let exitCode: Int?
        let meta: AnyJSON?
        let awaiting: Bool
    }

    private static var entries: [Key: ToolDescriptor] = [:]
    private static var order: [Key] = []
    private static let limit = 2_000

    static func describe(_ vm: ToolCallVM, awaiting: Bool) -> ToolDescriptor {
        let key = Key(id: vm.id, rawName: vm.rawName, toolName: vm.toolName, state: vm.state, input: vm.input, output: vm.output,
                      isError: vm.isError, exitCode: vm.exitCode, meta: vm.meta, awaiting: awaiting)
        if let hit = entries[key] { return hit }
        let descriptor = DescribeToolCall.describe(vm, awaiting: awaiting)
        entries[key] = descriptor
        order.append(key)
        if order.count > limit {
            let evicted = order.prefix(order.count - limit)
            for old in evicted { entries[old] = nil }
            order.removeFirst(evicted.count)
        }
        return descriptor
    }
}
