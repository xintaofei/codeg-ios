import Foundation
import Testing
@testable import Codeg

/// Codex `/goal` runs: the web's `groupGoalRuns` suite
/// (`src/lib/adapters/ai-elements-adapter.test.ts`, codeg 0.44), the goal
/// card's pure half (`goal-tool-call.test.tsx`), and how runs reach the iOS
/// adapters, the activity model and the timeline.
@MainActor
struct GoalRunsTests {
    // MARK: - Fixtures

    /// The web's `poll(toolName, taskId?)`: a settled call with no output.
    private func poll(_ toolName: String, _ taskId: String? = nil,
                      state: ToolCallState = .done) -> ToolCallVM {
        ToolCallVM(id: "\(toolName):\(taskId ?? "")", rawName: toolName, kind: "", state: state,
                   input: taskId.map { #"{"task_id":"\#($0)"}"# }, output: nil, content: nil, isError: false)
    }

    private func call(_ toolName: String, _ taskId: String? = nil, state: ToolCallState = .done) -> RenderPart {
        .tool(poll(toolName, taskId, state: state))
    }

    private let text: RenderPart = .text("checking again")

    private func goalCall(_ id: String, _ name: String, input: String? = nil, output: String? = nil,
                          state: ToolCallState = .done, isError: Bool = false) -> ToolCallVM {
        ToolCallVM(id: id, rawName: name, kind: "", state: state, input: input, output: output,
                   content: nil, isError: isError)
    }

    /// A part's shape, for comparing lists of parts (`RenderPart` is not
    /// `Equatable`).
    private func shape(_ part: RenderPart) -> String {
        switch part {
        case .text(let t): return "text:\(t)"
        case .proposedPlan(let markdown, _): return "proposed-plan:\(markdown)"
        case .reasoning(let t): return "reasoning:\(t)"
        case .liveText(let run, _): return "live-text:\(run.id)"
        case .liveReasoning(let run, _): return "live-reasoning:\(run.id)"
        case .tool(let vm): return "tool:\(vm.id)"
        case .image: return "image"
        case .goalRun(let run):
            return "goal-run(\(run.start.id)…\(run.end?.id ?? "nil"))[\(run.items.map(shape).joined(separator: ", "))]"
        default: return String(describing: part)
        }
    }

    private func types(_ parts: [RenderPart]) -> [String] {
        parts.map { part in
            switch part {
            case .text, .liveText: return "text"
            case .goalRun: return "goal-run"
            case .tool: return "tool-call"
            case .reasoning, .liveReasoning: return "reasoning"
            case .proposedPlan: return "proposed-plan"
            case .image: return "generated-image"
            default: return "other"
            }
        }
    }

    private func goalRun(_ part: RenderPart?) -> GoalRunPart? {
        if case .goalRun(let run)? = part { return run }
        Issue.record("expected a goal-run, got \(part.map(shape) ?? "nothing")")
        return nil
    }

    private func unfinished(_ items: [RenderPart], isRunning: Bool = true) -> RenderPart {
        .goalRun(GoalRunPart(start: poll("create_goal"), end: nil, items: items, isRunning: isRunning))
    }

    // MARK: - groupGoalRuns (web)

    @Test("wraps create_goal through update_goal with intervening process parts")
    func wrapsCreateGoalThroughUpdateGoalWithInterveningProcessParts() {
        let out = GoalRuns.group([
            call("create_goal"), text, call("exec_command"), call("update_goal"), .text("final answer"),
        ])
        #expect(types(out) == ["goal-run", "text"])
        guard let run = goalRun(out.first) else { return }
        #expect(run.start.toolName == "create_goal")
        #expect(run.end?.toolName == "update_goal")
        #expect(types(run.items) == ["text", "tool-call"])
        #expect(run.isRunning == false)
    }

    @Test("wraps an unfinished goal run as running while streaming")
    func wrapsAnUnfinishedGoalRunAsRunningWhileStreaming() {
        let out = GoalRuns.group([call("create_goal"), text], isStreaming: true)
        #expect(out.count == 1)
        guard let run = goalRun(out.first) else { return }
        #expect(run.end?.id == nil)
        #expect(run.items.map(shape) == [shape(text)])
        #expect(run.isRunning == true)
    }

    @Test("settles an unfinished goal run when not streaming")
    func settlesAnUnfinishedGoalRunWhenNotStreaming() {
        // codex leaves a `/goal` active without a closing update_goal, so a
        // stopped turn or a reloaded conversation must NOT spin the row
        // forever. Trailing prose is lifted out so the folded row does not
        // hide it.
        let out = GoalRuns.group([call("create_goal"), text], isStreaming: false)
        #expect(types(out) == ["goal-run", "text"])
        guard let run = goalRun(out.first) else { return }
        #expect(run.end?.id == nil)
        #expect(run.items.isEmpty)
        #expect(run.isRunning == false)
        #expect(out.last.map(shape) == shape(text))
    }

    @Test("lifts trailing prose out of a settled unfinished goal after tools")
    func liftsTrailingProseOutOfASettledUnfinishedGoalAfterTools() {
        let out = GoalRuns.group([call("create_goal"), call("exec_command"), text], isStreaming: false)
        #expect(types(out) == ["goal-run", "text"])
        #expect(goalRun(out.first).map { types($0.items) } == ["tool-call"])
        #expect(out.last.map(shape) == shape(text))
    }

    @Test("lifts a trailing proposed plan and generated image too")
    func liftsATrailingProposedPlanAndGeneratedImageToo() {
        // A Plan-mode document and a generated image ARE the turn's answer; a
        // folded row must not hide them either. Reasoning is process and
        // stays inside.
        let proposedPlan: RenderPart = .proposedPlan(markdown: "## Plan\n1. do the thing", streaming: false)
        let generatedImage: RenderPart = .image(ImageData(data: "", mimeType: "image/png", uri: nil), caption: nil)
        let reasoning: RenderPart = .reasoning(text: "thinking about it")
        let out = GoalRuns.group([call("create_goal"), reasoning, text, proposedPlan, generatedImage],
                                 isStreaming: false)
        #expect(types(out) == ["goal-run", "text", "proposed-plan", "generated-image"])
        #expect(goalRun(out.first).map { $0.items.map(shape) } == [shape(reasoning)])
        #expect(out.dropFirst().map(shape) == [text, proposedPlan, generatedImage].map(shape))
    }

    @Test("keeps mid-run prose inside a settled unfinished goal")
    func keepsMidRunProseInsideASettledUnfinishedGoal() {
        // Prose followed by more work is a mid-run note, not a wrap-up:
        // lifting it would reorder the reply, so the scan stops at the last
        // process part.
        let out = GoalRuns.group([call("create_goal"), .text("checking"), call("exec_command")],
                                 isStreaming: false)
        #expect(types(out) == ["goal-run"])
        #expect(goalRun(out.first).map { types($0.items) } == ["text", "tool-call"])
    }

    @Test("keeps the answer inside a live unfinished goal")
    func keepsTheAnswerInsideALiveUnfinishedGoal() {
        // While streaming, the row holds the answer and opens itself; lifting
        // mid-stream would make the prose jump out and back as tools
        // interleave.
        let proposedPlan: RenderPart = .proposedPlan(markdown: "## Plan", streaming: false)
        let out = GoalRuns.group([call("create_goal"), text, proposedPlan], isStreaming: true)
        #expect(types(out) == ["goal-run"])
        guard let run = goalRun(out.first) else { return }
        #expect(run.items.map(shape) == [text, proposedPlan].map(shape))
        #expect(run.isRunning == true)
    }

    // Adapted: Swift's parts are values, so the reopened run cannot be
    // mutated by the merge; what is left is that merging twice gives the same.
    @Test("does not mutate a reopened unfinished goal run when closing across turns")
    func doesNotMutateAReopenedUnfinishedGoalRunWhenClosingAcrossTurns() {
        let firstText: RenderPart = .text("started goal")
        let nextText: RenderPart = .text("continued goal")
        let reopened = unfinished([firstText])
        let firstMerge = GoalRuns.group([reopened, nextText, call("update_goal")])
        #expect(goalRun(firstMerge.first).map { $0.items.map(shape) } == [firstText, nextText].map(shape))
        #expect(goalRun(reopened).map { $0.items.map(shape) } == [shape(firstText)])
        let secondMerge = GoalRuns.group([reopened, nextText, call("update_goal")])
        #expect(goalRun(secondMerge.first).map { $0.items.map(shape) } == [firstText, nextText].map(shape))
    }

    @Test("merges repeated unfinished goal runs into one cross-turn card")
    func mergesRepeatedUnfinishedGoalRunsIntoOneCrossTurnCard() {
        let firstText: RenderPart = .text("started goal")
        let nextText: RenderPart = .text("continued goal")
        let out = GoalRuns.group([unfinished([firstText]), unfinished([]), nextText])
        #expect(types(out) == ["goal-run", "text", "text"])
        #expect(goalRun(out.first).map(\.items.isEmpty) == true)
        #expect(out.dropFirst().map(shape) == [firstText, nextText].map(shape))
    }

    @Test("closes an active cross-turn goal when the next turn already has a completed goal run")
    func closesAnActiveCrossTurnGoalWhenTheNextTurnAlreadyHasACompletedGoalRun() {
        let firstText: RenderPart = .text("started goal")
        let command = call("exec_command")
        let finalText: RenderPart = .text("final answer")
        let completed: RenderPart = .goalRun(GoalRunPart(start: poll("create_goal"), end: poll("update_goal"),
                                                         items: [command], isRunning: false))
        let out = GoalRuns.group([unfinished([firstText]), completed, finalText])
        #expect(types(out) == ["goal-run", "text"])
        #expect(goalRun(out.first).map { $0.items.map(shape) } == [firstText, command].map(shape))
        #expect(out.last.map(shape) == shape(finalText))
    }

    // MARK: - stale and closing runs

    private let objective = "分析 README 文件"

    // Adapted from the web's "keeps final text outside a completed goal when a
    // stale active update arrives after completion", whose goal updates are
    // prose markers (`Goal updated (…)`, not ported): here they are the calls.
    @Test("drops a create_goal for an objective a run already completed")
    func dropsACreateGoalForAnObjectiveARunAlreadyCompleted() throws {
        let out = GoalRuns.group([
            .tool(goalCall("g1", "create_goal", input: #"{"objective":"\#(objective)"}"#)),
            call("exec_command"),
            .tool(goalCall("g2", "update_goal", input: #"{"status":"complete"}"#,
                           output: #"{"goal":{"objective":"\#(objective)","status":"complete"}}"#)),
            .tool(goalCall("g3", "create_goal", input: #"{"objective":"\#(objective)"}"#)),
            .text("已完成 README 分析。"),
        ], isStreaming: true)
        #expect(types(out) == ["goal-run", "text"])
        let run = try #require(goalRun(out.first))
        #expect(run.end?.toolName == "update_goal")
        #expect(run.isRunning == false)
        #expect(!out.map(shape).joined().contains("g3"))
    }

    @Test("spills a stale unfinished run's parts into the reply")
    func spillsAStaleUnfinishedRunsPartsIntoTheReply() {
        let completed: RenderPart = .goalRun(GoalRunPart(
            start: goalCall("g1", "create_goal", input: #"{"objective":"\#(objective)"}"#),
            end: goalCall("g2", "update_goal", output: #"{"goal":{"objective":"\#(objective)"}}"#),
            items: [], isRunning: false))
        let stale: RenderPart = .goalRun(GoalRunPart(
            start: goalCall("g3", "create_goal", input: #"{"objective":"\#(objective)"}"#),
            end: nil, items: [.text("again")], isRunning: true))
        let out = GoalRuns.group([completed, stale])
        #expect(out.map(shape) == ["goal-run(g1…g2)[]", "text:again"])
    }

    @Test("keeps a run whose closing update_goal is still running, running")
    func keepsARunWhoseClosingUpdateGoalIsStillRunningRunning() {
        let out = GoalRuns.group([call("create_goal"), call("exec_command"), call("update_goal", state: .running)])
        #expect(goalRun(out.first)?.isRunning == true)
        #expect(goalRun(out.first)?.end?.id == "update_goal:")
    }

    @Test("starts and closes runs under any wrapper of the goal tools")
    func startsAndClosesRunsUnderAnyWrapperOfTheGoalTools() {
        let out = GoalRuns.group([call("functions.create_goal"), text, call("mcp__codeg__update_goal")])
        #expect(types(out) == ["goal-run"])
        #expect(goalRun(out.first)?.end?.id == "mcp__codeg__update_goal:")
    }

    @Test("leaves a closing call with no run open as a plain call")
    func leavesAClosingCallWithNoRunOpenAsAPlainCall() {
        let out = GoalRuns.group([text, call("update_goal")])
        #expect(types(out) == ["text", "tool-call"])
    }

    @Test("names a goal by its result's objective, else its argument")
    func namesAGoalByItsResultsObjectiveElseItsArgument() {
        #expect(GoalRuns.objectiveKey(of: goalCall("a", "update_goal", input: #"{"objective":"from input"}"#,
                                                   output: #"{"goal":{"objective":"  from output  "}}"#))
                == "from output")
        #expect(GoalRuns.objectiveKey(of: goalCall("b", "create_goal", input: #"{"objective":"from input"}"#,
                                                   output: "ok")) == "from input")
        #expect(GoalRuns.objectiveKey(of: goalCall("c", "create_goal", input: #"{"objective":"   "}"#)) == nil)
        #expect(GoalRuns.objectiveKey(of: goalCall("d", "update_goal", input: #"{"status":"complete"}"#)) == nil)
    }

    // MARK: - answer split (web `isTurnAnswerPart` / `splitTrailingAnswerParts`)

    @Test("treats a goal run as process, never the answer")
    func treatsAGoalRunAsProcessNeverTheAnswer() {
        let run = unfinished([.text("inside")], isRunning: false)
        #expect(BuildActivity.isAnswerPart(run) == false)
        let split = BuildActivity.splitTrailingAnswer([.text("before"), run, .text("after")])
        #expect(split.body.map(shape) == [shape(.text("before")), shape(run)])
        #expect(split.trailing.map(shape) == ["text:after"])
    }

    // MARK: - through the adapters

    private func assistant(_ id: String, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: blocks, timestamp: Date(timeIntervalSince1970: 1_792_000_000))
    }

    private var createBlock: ContentBlock {
        .toolUse(id: "g1", name: "create_goal", inputPreview: #"{"objective":"Tidy the README"}"#,
                 status: .unknown, meta: nil)
    }

    private var bashBlocks: [ContentBlock] {
        [
            .toolUse(id: "c1", name: "Bash", inputPreview: #"{"command":"ls"}"#, status: .unknown, meta: nil),
            .toolResult(id: "c1", outputPreview: "README.md", isError: false, agentStats: nil),
        ]
    }

    // Adapted from the web's `mergeRunParts` "merges whole when a member it
    // would keep holds a goal": iOS merges a reply's turns before adapting,
    // so a run reads across them in one pass.
    @Test("reads a run across the turns of one reply")
    func readsARunAcrossTheTurnsOfOneReply() {
        let merged = TranscriptTimeline.merge([
            assistant("a1", [.text("a"), createBlock]),
            assistant("a2", bashBlocks),
            assistant("a3", [.text("b")]),
        ])
        let running = MessageRender.adaptTurn(merged, liveness: .round)
        #expect(running.map(shape) == ["text:a", "goal-run(g1…nil)[tool:c1, text:b]"])
        #expect(goalRun(running.last)?.isRunning == true)

        // Out of the running round the same reply is a record: the goal codex
        // left open settles, and hands back its answer.
        let settled = MessageRender.adaptTurn(merged, liveness: .settled)
        #expect(settled.map(shape) == ["text:a", "goal-run(g1…nil)[tool:c1]", "text:b"])
        #expect(goalRun(settled[1])?.isRunning == false)
    }

    @Test("runs a live goal only while its turn streams")
    func runsALiveGoalOnlyWhileItsTurnStreams() {
        let live = LiveTurn()
        live.upsertToolCall(id: "g1", title: "Goal updated (active): \(objective)", kind: "other",
                            status: "completed", rawInput: #"{"objective":"\#(objective)"}"#,
                            rawOutput: nil, content: nil)
        live.appendText("Reading README.md")
        let streaming = MessageRender.adaptLive(live)
        #expect(types(streaming) == ["goal-run"])
        guard let run = goalRun(streaming.first) else { return }
        #expect(run.isRunning == true)
        #expect(types(run.items) == ["text"])

        live.isStreaming = false
        let stopped = MessageRender.adaptLive(live)
        #expect(types(stopped) == ["goal-run", "text"])
        #expect(goalRun(stopped.first)?.isRunning == false)
    }

    // MARK: - the activity model

    @Test("counts a goal's steps as the reply's, and not its own calls")
    func countsAGoalsStepsAsTheRepliesAndNotItsOwnCalls() {
        let read = ToolCallVM(id: "r1", rawName: "Read", kind: "", state: .done,
                              input: #"{"file_path":"/r/a.ts"}"#, output: "x", content: nil, isError: false)
        let failing = ToolCallVM(id: "b1", rawName: "Bash", kind: "", state: .error, input: #"{"command":"make"}"#,
                                 output: "Exit code 1", content: nil, isError: true)
        let retried = ToolCallVM(id: "b2", rawName: "Bash", kind: "", state: .done, input: #"{"command":"make"}"#,
                                 output: "ok", content: nil, isError: false)
        let parts: [RenderPart] = [
            .goalRun(GoalRunPart(start: poll("create_goal"), end: poll("update_goal"),
                                 items: [.tool(read), .tool(failing)], isRunning: false)),
            .tool(retried),
            .text("Built."),
        ]
        let model = BuildActivity.build(parts, isStreaming: false)
        #expect(model.items.map(\.key) == ["goal:create_goal:", "tool:b2"])
        #expect(model.summary.steps == 3)
        #expect(model.summary.counts.commands == 2)
        #expect(model.summary.counts.readFiles == 1)
        // The retry outside the run recovers the failure inside it.
        #expect(model.summary.failed == 1)
        #expect(model.summary.unrecovered == 0)
        #expect(model.summary.recoveredKeys == ["tool:b1"])
    }

    @Test("names a reply that opens with a goal by its opening call")
    func namesAReplyThatOpensWithAGoalByItsOpeningCall() {
        let run: RenderPart = .goalRun(GoalRunPart(start: poll("create_goal"), end: nil,
                                                   items: [.text("note")], isRunning: false))
        #expect(BuildActivity.replyAnchor([run]) == "create_goal:")
    }

    // MARK: - the timeline

    @Test("draws a settled reply's run as one goal row, its answer kept in view")
    func drawsASettledRepliesRunAsOneGoalRowItsAnswerKeptInView() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("/goal tidy the README")], timestamp: date),
            assistant("a", [createBlock] + bashBlocks + [.text("Tidied.")]),
        ]
        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .codex,
                                                       suppressInFlight: false)
        let goal = nodes.first { $0.id == "goal-g1" }
        guard let goal, case .goal(let step) = goal.content else {
            Issue.record("the run is a goal row"); return
        }
        #expect(goal.reply?.role == .body)
        #expect(step.facts.objective == "Tidy the README")
        #expect(step.run.isRunning == false)
        #expect(step.model.items.map(\.key) == ["tool:c1"])
        if case .tool(let icon, let state) = goal.marker {
            #expect(icon == "target")
            #expect(state == .done)
        } else {
            Issue.record("the goal row wears a tool marker")
        }
        let answer = nodes.first { if case .assistantText("Tidied.") = $0.content { return true }; return false }
        #expect(answer?.reply?.role == .always)
        #expect(!nodes.contains { $0.id == "tool-c1" }, "the run's calls are drawn inside its row")

        let body = TranscriptTimeline.goalBodyNodes(step, agent: .codex)
        #expect(body.map(\.id) == ["tool-c1"])
        #expect(body.first?.connectTop == false)
        #expect(body.last?.connectBottom == false)
    }

    @Test("draws a goal call outside any run as a goal row too")
    func drawsAGoalCallOutsideAnyRunAsAGoalRowToo() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("carry on")], timestamp: date),
            assistant("a", bashBlocks + [
                .toolUse(id: "u1", name: "update_goal", inputPreview: #"{"status":"complete"}"#,
                         status: .unknown, meta: nil),
                .toolResult(id: "u1", outputPreview: #"{"goal":{"objective":"Tidy the README","status":"complete"}}"#,
                            isError: false, agentStats: nil),
                .text("Done."),
            ]),
        ]
        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .codex,
                                                       suppressInFlight: false)
        guard let row = nodes.first(where: { $0.id == "tool-u1" }), case .goal(let step) = row.content else {
            Issue.record("the lone call is a goal row"); return
        }
        #expect(step.facts.objective == "Tidy the README")
        #expect(ActivityGoal.Status.of(step.facts.status) == .complete)
        #expect(step.model.items.isEmpty)
    }

    // MARK: - goal facts (web `goal-tool-call.test.tsx`, its pure half)

    @Test("reads a Codex goal completion's objective, usage and time")
    func readsACodexGoalCompletionsObjectiveUsageAndTime() {
        let end = goalCall("call-goal", "update_goal", input: #"{"status":"complete"}"#, output: """
        {"goal":{"objective":"Analyze README file","status":"complete","tokensUsed":5184,"timeUsedSeconds":19},\
        "completionBudgetReport":"Goal achieved. Report final usage from this tool result's structured goal fields."}
        """)
        let facts = ActivityGoal.facts(start: end, end: nil)
        #expect(facts.objective == "Analyze README file")
        #expect(ActivityGoal.Status.of(facts.status) == .complete)
        #expect(facts.tokensUsed.map(ActivityGoal.compactTokens) == "5.2K")
        #expect(facts.timeUsedSeconds.map { ActivityGoal.duration(seconds: $0) } == "19s")
    }

    @Test("reads a create_goal under a wrapper as active")
    func readsACreateGoalUnderAWrapperAsActive() {
        let start = goalCall("call-create-goal", "functions.create_goal", input: #"{"objective":"Analyze README file"}"#)
        let facts = ActivityGoal.facts(start: start, end: nil)
        #expect(facts.objective == "Analyze README file")
        #expect(ActivityGoal.Status.of(facts.status) == .active)
    }

    @Test("prefers the closing call's word, then the opening call's")
    func prefersTheClosingCallsWordThenTheOpeningCalls() {
        let start = goalCall("s", "create_goal", input: #"{"objective":"Old","token_budget":50000}"#,
                             output: #"{"goal":{"tokens_used":100},"remaining_tokens":49900}"#)
        let end = goalCall("e", "update_goal", input: #"{"status":"paused"}"#,
                           output: #"{"goal":{"objective":"New","tokensUsed":2000}}"#)
        let facts = ActivityGoal.facts(start: start, end: end)
        #expect(facts.objective == "New")
        #expect(facts.status == "paused")
        #expect(facts.tokensUsed == 2000)
        #expect(facts.tokenBudget == 50000)
        #expect(facts.remainingTokens == 49900)
    }

    @Test("shows a fenced error without its fence")
    func showsAFencedErrorWithoutItsFence() {
        let start = goalCall("call-create-goal", "create_goal", input: #"{"objective":"Analyze README file"}"#,
                             output: "```\nGoal already active.\n```", state: .error, isError: true)
        #expect(ActivityGoal.isError(start: start, end: nil))
        #expect(ActivityGoal.errorText(start: start, end: nil) == "Goal already active.")
        #expect(ActivityGoal.unwrapWholeFence("```\na\n```\nmore\n```") == "```\na\n```\nmore\n```")
        #expect(ActivityGoal.unwrapWholeFence("plain") == "plain")
    }

    @Test("words a status the way the row reads it")
    func wordsAStatusTheWayTheRowReadsIt() {
        #expect(ActivityGoal.Status.of("Usage-Limited") == .usageLimited)
        #expect(ActivityGoal.Status.of("usage-limited")?.tone == .error)
        #expect(ActivityGoal.Status.of("completed") == .complete)
        #expect(ActivityGoal.Status.of("paused")?.tone == .muted)
        #expect(ActivityGoal.Status.of("failed")?.tone == .error)
        #expect(ActivityGoal.Status.of("weird") == .other("weird"))
        #expect(ActivityGoal.Status.of(nil) == nil)
    }

    @Test("formats token counts and times as JavaScript does")
    func formatsTokenCountsAndTimesAsJavaScriptDoes() {
        #expect(ActivityGoal.compactTokens(512) == "512")
        #expect(ActivityGoal.compactTokens(1000) == "1K")
        #expect(ActivityGoal.compactTokens(5184) == "5.2K")
        // `toFixed` breaks an exact tie up; 1.15 is not one in binary.
        #expect(ActivityGoal.compactTokens(1250) == "1.3K")
        #expect(ActivityGoal.compactTokens(1150) == "1.1K")
        #expect(ActivityGoal.compactTokens(-1250) == "-1.3K")
        #expect(ActivityGoal.duration(seconds: 59.5) == "60s")
        #expect(ActivityGoal.duration(seconds: 90) == "1.5m")
        #expect(ActivityGoal.duration(seconds: 7200) == "2h")
        #expect(ActivityGoal.toFixed1(0.04) == "0.0")
        #expect(ActivityGoal.toFixed1(0.05) == "0.1")
    }
}
