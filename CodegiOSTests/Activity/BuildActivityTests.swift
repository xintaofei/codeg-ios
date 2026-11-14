import Foundation
import Testing
@testable import Codeg

/// The redesign's reference turn (`src/lib/activity/__fixtures__/mockup-turn.ts`),
/// as iOS `MessageTurn`s.
@MainActor
enum MockupTurn {
    static let repo = "/Users/demo/hvac"

    /// JSON text for a tool input or result (`JSON.stringify`; key order is
    /// irrelevant to every reader these fixtures feed).
    static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func toolUse(_ id: String, _ name: String, _ input: [String: Any], meta: [String: Any]? = nil,
                        status: ToolUseStatus = .unknown) -> ContentBlock {
        .toolUse(id: id, name: name, inputPreview: json(input), status: status, meta: meta.map(AnyJSON.init(any:)))
    }

    static func toolResult(_ id: String, _ output: String, isError: Bool = false) -> ContentBlock {
        .toolResult(id: id, outputPreview: output, isError: isError, agentStats: nil)
    }

    static func fixtureLines(_ n: Int, _ prefix: String) -> String {
        (1...n).map { "\(prefix) line \($0)" }.joined(separator: "\n")
    }

    static func turn(_ id: String, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: blocks, timestamp: Date(timeIntervalSince1970: 1_792_000_000))
    }

    /// The web's `adaptMessageTurn(turn, …).content`.
    static func parts(_ turn: MessageTurn, liveness: ToolLiveness = .settled) -> [RenderPart] {
        MessageRender.adaptTurn(turn, liveness: liveness)
    }

    private static let delegationTaskId = "14be49e7-2b1c-4c3e-9d7a-0f5e1a2b3c4d"
    private static let delegationTask =
        "Update the stale snapshot in web/lib/__fixtures__/tasks.json to match active-only bindings, then review the audit/report/state artifacts for regressions."

    static var assistantBlocks: [ContentBlock] {
        [
            .thinking("**Summarizing log status**\n\nI need to gather the logs and check the status succinctly while capturing all commands. Review prior tests first, inspect the relevant code without introducing new changes, and check the root Makefile docs to make sure nothing is missing."),
            toolUse("t1", "Read", ["file_path": "\(repo)/Makefile"]),
            toolResult("t1", fixtureLines(84, "Makefile")),
            toolUse("t2", "Read", ["file_path": "\(repo)/web/package.json"]),
            toolResult("t2", fixtureLines(41, "package.json")),
            toolUse("t3", "Read", ["file_path": "\(repo)/agent/src/hvac_agent/query_tasks.py"]),
            toolResult("t3", fixtureLines(212, "query_tasks.py")),
            toolUse("t4", "Grep", ["pattern": "source_bindings", "path": "agent/src"]),
            toolResult("t4", [
                #"agent/src/hvac_agent/query_tasks.py:44:            "source_bindings": tuple(binding for binding in item.source_bindings),"#,
                "agent/src/hvac_agent/query_tasks.py:88:    source_bindings: tuple[Binding, ...]",
                "agent/src/hvac_agent/report.py:17:    for b in task.source_bindings:",
                "agent/src/hvac_agent/state.py:203:        source_bindings=(),",
            ].joined(separator: "\n")),
            toolUse("t5", "Bash", [
                "command": "git diff --check; git status --short -- web; tail -25 .local/hvac-audit-followup-20261022/web-build.log; tail -6 .local/hvac-audit-followup-20261022/root-unittest.log",
                "description": "Check build and unit-test logs",
            ]),
            toolResult("t5", [
                "> next build", "", "▲ Next.js 16.4.0 (Turbopack)", "- Environments: .env.local",
                "✓ Running next.config.ts took 52ms", "", "  Creating an optimized production build ...",
                "✓ Compiled successfully in 2.8s", "✓ Generating static pages (14/14)", "", "Ran 31 tests", "OK",
            ].joined(separator: "\n")),
            toolUse("t6", "Bash", ["command": [
                "agent/.venv/bin/python - <<'PY'",
                "import json",
                "from hvac_agent.query_tasks import load_tasks",
                "tasks = load_tasks('.local/hvac-audit-followup-20261022/state.json')",
                "for t in tasks:",
                "    print(t.id, len(t.source_bindings))",
                "PY",
            ].joined(separator: "\n")]),
            toolResult("t6", "T-101 3\nT-102 2\nT-103 3"),
            toolUse("t7", "mcp__linear__get_issue", ["id": "HVAC-212"]),
            toolResult("t7", """
            {
              "title": "Inactive bindings leak into report",
              "state": "In Progress",
              "labels": [
                "audit",
                "agent"
              ]
            }
            """),
            .thinking("**Planning the fix**\n\nThe report copies every binding, including inactive ones. Filter where the tuple is built."),
            toolUse("t8", "Edit", [
                "file_path": "\(repo)/agent/src/hvac_agent/query_tasks.py",
                "old_string": #"            "source_bindings": tuple(binding for binding in item.source_bindings),"#,
                "new_string": "            \"source_bindings\": tuple(\n                binding for binding in item.source_bindings if binding.active\n            ),",
                "_start_line": 44,
            ]),
            toolResult("t8", "The file \(repo)/agent/src/hvac_agent/query_tasks.py has been updated successfully."),
            toolUse("t9", "Bash", ["command": "pnpm --filter web test", "description": "Run web unit tests"]),
            toolResult("t9", [
                "FAIL  web/lib/tasks.test.ts > maps inactive bindings", "  Expected: 2", "  Received: 3", "",
                "  at web/lib/tasks.test.ts:58:22", "", "Tests: 1 failed, 47 passed, 48 total", "", "Exit code 1",
            ].joined(separator: "\n"), isError: true),
            .text("The snapshot still encodes the old behavior, so I'm handing that update to Codex."),
            toolUse("t10", "mcp__codeg-mcp__delegate_to_agent",
                    ["agent_type": "codex", "task": delegationTask],
                    meta: ["codeg.delegation": [
                        "status": "completed", "child_conversation_id": 77,
                        "task_id": delegationTaskId, "task_preview": delegationTask,
                    ]]),
            toolResult("t10", json(["task_id": delegationTaskId, "status": "started"])),
            toolUse("t11", "mcp__codeg-mcp__get_delegation_status", ["task_ids": [delegationTaskId], "wait_ms": 60000]),
            toolResult("t11", json([
                "task_id": delegationTaskId, "status": "completed",
                "text": "Snapshot updated. 48/48 passing, no regressions in audit artifacts.",
                "duration_ms": 94000,
                "progress": ["steps": 5, "marks": ["ok", "ok", "failed", "ok", "ok"], "last_step": "pnpm --filter web test"],
            ])),
            toolUse("t12", "Bash", ["command": "pnpm --filter web test", "description": "Run web unit tests"]),
            toolResult("t12", "Tests: 48 passed, 48 total"),
            toolUse("t13", "Bash", [
                "command": "python scripts/regen_report.py", "description": "Regenerate audit report",
                "run_in_background": true,
            ]),
            toolResult("t13", "Command running in background with ID: beecec7d. Output is being written to: /tmp/claude/tasks/beecec7d.output"),
            toolUse("t14", "TaskOutput", ["task_id": "beecec7d", "block": true, "timeout": 600000]),
            toolResult("t14", "<retrieval_status>success</retrieval_status>\n<task_id>beecec7d</task_id>\n<task_type>local_bash</task_type>\n<status>completed</status>\n<exit_code>0</exit_code>\n<output>report.md written</output>"),
            toolUse("t15", "Bash", [
                "command": #"git commit -am "fix: filter inactive source bindings""#, "description": "Commit the fix",
            ]),
            toolResult("t15", "[audit-followup 3f2a91c] fix: filter inactive source bindings\n 2 files changed, 4 insertions(+), 2 deletions(-)"),
            .text([
                "The web build is clean and the unit suite now passes 48/48.",
                "",
                "The failure came from `query_tasks.model_copy` copying inactive source bindings into the report. I filtered them where the tuple is built, and Codex updated the snapshot that encoded the old behavior.",
                "",
                "- `agent/src/hvac_agent/query_tasks.py` skips bindings where `active` is false",
                "- `web/lib/__fixtures__/tasks.json` snapshot updated by Codex",
                "",
                "Committed as `3f2a91c` on `audit-followup`. The regenerated report is at `.local/hvac-audit-followup-20261022/report.md`.",
            ].joined(separator: "\n")),
        ]
    }

    static var assistantTurn: MessageTurn { turn("turn-assistant", assistantBlocks) }

    /// The same work caught mid-turn: a test command still running. `l3Status`
    /// stands in for the web's in-progress id set (read with `.status` liveness).
    static func liveBlocks(l3Status: ToolUseStatus = .unknown) -> [ContentBlock] {
        [
            .thinking("**Checking the failing test**\n\nThe snapshot test still fails; look at the fixture first."),
            toolUse("l1", "Read", ["file_path": "\(repo)/web/lib/__fixtures__/tasks.json"]),
            toolResult("l1", fixtureLines(40, "tasks.json")),
            toolUse("l2", "Grep", ["pattern": "inactive", "path": "web/lib"]),
            toolResult("l2", "web/lib/tasks.test.ts:58:    expect(mapBindings(fixture)).toHaveLength(2)"),
            toolUse("l3", "Bash", ["command": "pnpm --filter web test -- --watch=false", "description": "Run web unit tests"],
                    status: l3Status),
            toolResult("l3", [
                "> web@0.1.0 test", "> vitest run", "", " RUN  v4.0.2 /Users/demo/hvac/web", "",
                " ✓ lib/report.test.ts (12 tests) 41ms", " ✓ lib/state.test.ts (9 tests) 22ms",
            ].joined(separator: "\n")),
        ]
    }
}

/// `src/lib/activity/build-activity.test.ts` (codeg 0.44).
@MainActor
struct BuildActivityTests {
    private typealias M = MockupTurn

    private func text(_ text: ActivityText) -> String {
        switch text {
        case .settled(let s): return s
        case .live(let run, _): return run.fullText
        }
    }

    private func rows(_ items: [ActivityItem]) -> [String] {
        items.map { item in
            switch item {
            case .group(_, let kind, let steps, _):
                return "\(kind.rawValue)(\(steps.map(\.call.id).joined(separator: ",")))"
            case .step(let step):
                switch step {
                case .tool(let t): return "\(t.tool.kind.rawValue):\(t.call.id)"
                case .thought(_, let body, let streaming):
                    return "thought:\(ThoughtTitle.thoughtTitle(text(body), streaming: streaming) ?? "null")"
                case .note: return "note"
                case .delegationPolls: return "delegation-polls"
                case .backgroundTasks: return "background-tasks"
                case .taskList: return "task-list"
                case .compaction: return "compaction"
                case .image: return "image"
                case .plan: return "plan"
                case .unsupported: return "unsupported"
                case .goal(let goal): return "goal:\(goal.run.start.id)"
                }
            }
        }
    }

    private func toolStep(_ model: ReplyActivity, _ id: String) -> ActivityToolStep? {
        model.steps.lazy.compactMap(\.toolStep).first { $0.call.id == id }
    }

    private func laterPolls(_ model: ReplyActivity, _ id: String) -> [String]? {
        toolStep(model, id)?.laterPolls?.map(\.id)
    }

    private var reference: ReplyActivity {
        BuildActivity.build(M.parts(M.assistantTurn), isStreaming: false)
    }

    // MARK: - on the reference turn

    @Test("draws one row per step, with exploration and commands folded")
    func drawsOneRowPerStepWithExplorationAndCommandsFolded() {
        #expect(rows(reference.items) == [
            "thought:Summarizing log status",
            "explore(t1,t2,t3,t4)",
            "command(t5,t6)",
            "mcp:t7",
            "thought:Planning the fix",
            "edit:t8",
            "command:t9",
            "note",
            "delegation:t10",
            "delegation-polls",
            "command(t12,t13)",
            "background-tasks",
            "command:t15",
        ])
    }

    // iOS addition (the web checks this in its row tests): the lane is keyed
    // by its first poll, and names the task by the command that started it.
    @Test("keys the background-task lane by its poll and names the task's launch")
    func keysTheBackgroundTaskLaneByItsPollAndNamesTheTasksLaunch() {
        guard let lane = reference.steps.lazy.compactMap({ step -> BackgroundTasksStep? in
            if case .backgroundTasks(let lane) = step { return lane }
            return nil
        }).first else {
            Issue.record("expected a background-tasks step"); return
        }
        #expect(lane.key == "bg:t14")
        #expect(lane.status == .succeeded)
        #expect(lane.launches["beecec7d"] == BackgroundLaunch(
            stepKey: "tool:t13", command: "python scripts/regen_report.py",
            description: "Regenerate audit report"))
        #expect(lane.rows.map(\.taskId) == ["beecec7d"])
        guard let row = lane.rows.first else { return }
        #expect(row.badge == .completed)
        #expect(BackgroundTask.rowDetail(row, launch: lane.launches["beecec7d"])
                == "Regenerate audit report · report.md written")
    }

    @Test("hands a delegation its status poll, drawn as a row of its own")
    func handsADelegationItsStatusPollDrawnAsARowOfItsOwn() {
        #expect(laterPolls(reference, "t10") == ["t11"])
    }

    @Test("hands a delegation every check on its task, before or after other work")
    func handsADelegationEveryCheckOnItsTaskBeforeOrAfterOtherWork() {
        // Each check is a row of its own, the one right after the hand-over too;
        // the delegation reads the newest.
        let task = "a1b2c3d4"
        func status(_ id: String) -> ContentBlock {
            M.toolUse(id, "mcp__codeg-mcp__get_delegation_status", ["task_ids": [task], "wait_ms": 3000])
        }
        let turn = M.turn("turn-later-check", [
            M.toolUse("d1", "mcp__codeg-mcp__delegate_to_agent", ["agent_type": "claude_code", "task": "Run the four checks."]),
            M.toolResult("d1", M.json(["task_id": task, "status": "started"])),
            status("d2"),
            M.toolResult("d2", M.json(["task_id": task, "status": "running"])),
            .text("Still waiting on the sub-agent."),
            status("d3"),
            M.toolResult("d3", M.json(["task_id": task, "status": "completed", "text": "Done."])),
            .text("All done."),
        ])
        let later = BuildActivity.build(M.parts(turn), isStreaming: false)
        #expect(rows(later.items) == ["delegation:d1", "delegation-polls", "note", "delegation-polls"])
        #expect(later.steps.first?.toolStep?.laterPolls?.map(\.id) == ["d2", "d3"])
    }

    @Test("hands a resume the checks after it, and the call before it only the earlier ones")
    func handsAResumeTheChecksAfterItAndTheCallBeforeItOnlyTheEarlierOnes() {
        let task = "a1b2c3d4"
        func status(_ id: String) -> ContentBlock {
            M.toolUse(id, "mcp__codeg-mcp__get_delegation_status", ["task_ids": [task]])
        }
        let turn = M.turn("turn-resume-check", [
            M.toolUse("d1", "mcp__codeg-mcp__delegate_to_agent", ["agent_type": "codex", "task": "Review the patch."]),
            M.toolResult("d1", M.json(["task_id": task, "status": "started"])),
            status("d2"),
            M.toolResult("d2", M.json(["task_id": task, "status": "canceled"])),
            M.toolUse("r1", "mcp__codeg-mcp__resume_delegation", ["task_id": task]),
            M.toolResult("r1", M.json(["task_id": task, "status": "running", "agent_type": "codex", "child_conversation_id": 9])),
            status("d3"),
            M.toolResult("d3", M.json(["task_id": task, "status": "completed", "text": "Done."])),
        ])
        let model = BuildActivity.build(M.parts(turn), isStreaming: false)
        #expect(laterPolls(model, "d1") == ["d2"])
        #expect(laterPolls(model, "r1") == ["d3"])
    }

    @Test("leaves a refused resume out of the checks: the call before it still ends",
          arguments: [("completed", 0), ("failed", 1)])
    func leavesARefusedResumeOutOfTheChecks(_ ending: String, _ failed: Int) {
        let task = "a1b2c3d4"
        let turn = M.turn("turn-refused-resume", [
            M.toolUse("d1", "mcp__codeg-mcp__delegate_to_agent", ["agent_type": "codex", "task": "Review the patch."]),
            M.toolResult("d1", M.json(["task_id": task, "status": "started"])),
            M.toolUse("r1", "mcp__codeg-mcp__resume_delegation", ["task_id": task]),
            M.toolResult("r1", M.json([
                "task_id": task, "status": "running", "error_code": "not_resumable", "agent_type": "codex",
                "child_conversation_id": 9, "message": "Not resumed: the task is still running.",
            ])),
            M.toolUse("d2", "mcp__codeg-mcp__get_delegation_status", ["task_ids": [task]]),
            M.toolResult("d2", M.json(["task_id": task, "status": ending, "text": "Done."])),
        ])
        let model = BuildActivity.build(M.parts(turn), isStreaming: false)
        #expect(laterPolls(model, "d1") == ["d2"])
        #expect(laterPolls(model, "r1") == nil)
        #expect(model.summary.running == false)
        // A failed task is the delegation's failure, counted once.
        #expect(model.summary.failed == failed)
    }

    // iOS addition: an opencode code-mode delegation's script returns whatever
    // it returns, so the task id it is checked by comes off the broker's meta
    // (web `delegateCallTaskId`) — and the checks on that task are its own.
    @Test("hands an opencode code-mode delegation the checks on the task its meta names")
    func handsACodeModeDelegationTheChecksOnItsTask() {
        let task = "a1b2c3d4"
        let code = #"await tools["codeg-mcp"].delegate_to_agent({ agent_type: "codex", task: `Review the patch.` })"#
        let turn = M.turn("turn-code-mode-delegation", [
            M.toolUse("c1", "execute", ["code": code],
                      meta: ["codeg.delegation": ["status": "running", "task_id": task]]),
            M.toolResult("c1", "undefined"),
            M.toolUse("d2", "mcp__codeg-mcp__get_delegation_status", ["task_ids": [task]]),
            M.toolResult("d2", M.json(["task_id": task, "status": "completed", "text": "Done."])),
        ])
        let model = BuildActivity.build(M.parts(turn), isStreaming: false)
        #expect(rows(model.items) == ["delegation:c1", "delegation-polls"])
        #expect(laterPolls(model, "c1") == ["d2"])
        #expect(model.summary.counts.agents == 1)
        #expect(model.summary.counts.commands == 0)
    }

    @Test("keeps the closing prose as the answer")
    func keepsTheClosingProseAsTheAnswer() {
        let answer = reference.answer
        #expect(answer.count == 1)
        if case .text? = answer.first {} else { Issue.record("expected a text answer, got \(answer)") }
    }

    @Test("summarizes the turn")
    func summarizesTheTurn() {
        let summary = reference.summary
        #expect(summary.steps == 14)
        #expect(summary.counts == ActivityCounts(commands: 6, editedFiles: 1, agents: 1, mcp: 1, web: 0,
                                                 readFiles: 3, searches: 1))
        #expect(summary.failed == 1)
        #expect(summary.unrecovered == 0)
        #expect(summary.interrupted == 0)
        #expect(summary.running == false)
        #expect(summary.firstUnrecoveredKey == nil)
        #expect(summary.recoveredKeys == ["tool:t9"])
    }

    @Test("describes the rows the way the mockup shows them")
    func describesTheRowsTheWayTheMockupShowsThem() {
        let model = reference
        func tool(_ id: String) -> ToolDescriptor? { toolStep(model, id)?.tool }
        #expect(tool("t1")?.metric == .lines(84))
        #expect(tool("t4")?.metric == .matches(count: 4, files: 3))
        #expect(tool("t6")?.command?.heredoc?.bodyLines == 5)
        #expect(tool("t7")?.detail == "HVAC-212 · Inactive bindings leak into report")
        let file = tool("t8")?.files?.first
        #expect(file?.additions == 3)
        #expect(file?.deletions == 1)
        #expect(file?.lineRange == 44...46)
        #expect(tool("t9")?.exit == CommandExit(code: 1, signal: nil))
        #expect(tool("t13")?.background == ToolDescriptor.Background(taskId: "beecec7d"))
    }

    // Skipped: "is cached per parts array and streaming state" — the web's
    // WeakMap model cache is object-identity reuse; iOS builds value models.

    // MARK: - on a live turn

    @Test("reports the running command and keeps every call visible")
    func reportsTheRunningCommandAndKeepsEveryCallVisible() {
        // The web's in-progress id set (`["l3"]`) is l3's own `running` status
        // here, which `.status` liveness honours on a paired call.
        let parts = M.parts(M.turn("turn-live", M.liveBlocks(l3Status: .running)), liveness: .status)
        let model = BuildActivity.build(parts, isStreaming: true)
        #expect(rows(model.items) == ["thought:Checking the failing test", "explore(l1,l2)", "command:l3"])
        #expect(model.summary.running)
        guard model.items.count == 3, case .step(.tool(let last)) = model.items[2] else {
            Issue.record("expected a tool row last"); return
        }
        #expect(last.tool.status == .running)
    }

    @Test("titles a streaming thought by its newest heading")
    func titlesAStreamingThoughtByItsNewestHeading() {
        let run = LiveTextRun("**First**\n\nbody\n\n**Second**\n\nmore")
        let model = BuildActivity.build([.liveReasoning(run, streaming: true)], isStreaming: true)
        #expect(rows(model.items) == ["thought:Second"])
        #expect(model.summary.running)
    }

    // MARK: - on a reply rebuilt from fresh parts

    // Skipped: "keeps every step and row whose content did not change" and
    // "builds again only the step that changed, and only its row" — both assert
    // object identity across rebuilds (`lastBuilt` / `keepItems`), which iOS's
    // value-typed model has no counterpart of.

    // Adapted: the identity assertions (`toBe`) are dropped; what is left is
    // the rows a growing reply draws, whose earlier rows keep their keys.
    @Test("redraws a group a call joins, and keeps the rows before it")
    func redrawsAGroupACallJoinsAndKeepsTheRowsBeforeIt() {
        func live(_ extra: [ContentBlock]) -> [RenderPart] {
            M.parts(M.turn("turn-live", M.liveBlocks() + extra))
        }
        let before = BuildActivity.build(live([]), isStreaming: true)
        let after = BuildActivity.build(live([M.toolUse("l4", "Bash", ["command": "pnpm --filter web build"])]),
                                        isStreaming: true)
        #expect(rows(after.items) == ["thought:Checking the failing test", "explore(l1,l2)", "command(l3,l4)"])
        #expect(after.items.prefix(2).map(\.key) == before.items.prefix(2).map(\.key))
        #expect(toolStep(after, "l3")?.key == toolStep(before, "l3")?.key)
    }

    // Adapted: the identity assertions on the kept steps are dropped.
    @Test("hands a kept delegation the check that came after it")
    func handsAKeptDelegationTheCheckThatCameAfterIt() {
        let task = "a1b2c3d4"
        let blocks: [ContentBlock] = [
            M.toolUse("d1", "mcp__codeg-mcp__delegate_to_agent", ["agent_type": "codex", "task": "Update the snapshot."]),
            M.toolResult("d1", M.json(["task_id": task, "status": "started"])),
            M.toolUse("d2", "mcp__codeg-mcp__get_delegation_status", ["task_ids": [task]]),
            M.toolResult("d2", M.json(["task_id": task, "status": "running"])),
        ]
        func build(_ more: [ContentBlock]) -> ReplyActivity {
            BuildActivity.build(M.parts(M.turn("turn-kept-delegation", blocks + more)), isStreaming: true)
        }
        let before = build([])
        #expect(before.steps.first?.toolStep?.laterPolls?.map(\.id) == ["d2"])
        let after = build([
            .text("Still waiting on it."),
            M.toolUse("d3", "mcp__codeg-mcp__get_delegation_status", ["task_ids": [task]]),
            M.toolResult("d3", M.json(["task_id": task, "status": "completed", "text": "Done."])),
        ])
        #expect(after.steps.first?.toolStep?.laterPolls?.map(\.id) == ["d2", "d3"])
        #expect(after.steps[1].key == before.steps[1].key)
    }

    // MARK: - edge cases

    @Test("keeps a goal run's prose inside the run, where it is drawn")
    func keepsAGoalRunsProseInsideTheRunWhereItIsDrawn() {
        let start = ToolCallVM(id: "g1", rawName: "create_goal", kind: "", state: .done,
                               input: #"{"objective":"Ship it"}"#, output: "ok", content: nil, isError: false)
        let parts: [RenderPart] = [
            .goalRun(GoalRunPart(start: start, end: nil, items: [.tool(read("r1")), .text("Halfway there.")],
                                 isRunning: true)),
        ]
        let model = BuildActivity.build(parts, isStreaming: true)
        let goal = model.steps.lazy.compactMap { step -> ActivityGoalStep? in
            if case .goal(let goal) = step { return goal }
            return nil
        }.first
        guard let goal else { Issue.record("expected a goal step"); return }
        #expect(goal.model.answer.isEmpty)
        #expect(rows(goal.model.items) == ["read:r1", "note"])
    }

    private func read(_ id: String) -> ToolCallVM {
        ToolCallVM(id: id, rawName: "Read", kind: "", state: .done, input: #"{"file_path":"/r/a.ts"}"#,
                   output: "x", content: nil, isError: false)
    }

    private func texts(_ parts: [RenderPart]) -> [String?] {
        parts.map { if case .text(let t) = $0 { return t }; return nil }
    }

    @Test("returns an empty timeline for a text-only reply")
    func returnsAnEmptyTimelineForATextOnlyReply() {
        let model = BuildActivity.build([.text("Hi")], isStreaming: false)
        #expect(model.items.isEmpty)
        #expect(texts(model.answer) == ["Hi"])
        #expect(model.summary.steps == 0)
    }

    @Test("keeps prose written between steps as a note")
    func keepsProseWrittenBetweenStepsAsANote() {
        let model = BuildActivity.build([.text("Looking around."), .tool(read("a")), .text("Done.")], isStreaming: false)
        #expect(rows(model.items) == ["note", "read:a"])
        #expect(texts(model.answer) == ["Done."])
    }

    @Test("leaves out an interrupted call that carried nothing, but counts it")
    func leavesOutAnInterruptedCallThatCarriedNothingButCountsIt() {
        func interrupted(_ id: String, _ input: String) -> RenderPart {
            .tool(ToolCallVM(id: id, rawName: "Bash", kind: "", state: .error, input: input,
                             output: "[Request interrupted by user for tool use]", content: nil, isError: true))
        }
        let model = BuildActivity.build([interrupted("a", "{}"), interrupted("b", #"{"command":"pnpm dev"}"#)],
                                        isStreaming: false)
        #expect(rows(model.items) == ["command:b"])
        #expect(model.summary.interrupted == 2)
        #expect(model.summary.failed == 0)
    }

    // iOS regression (not in the web suite): the web anchors a reply with no
    // call and no long opening prose by a hash of its first part, so two
    // replies of a short thought and an answer keep apart.
    @Test("tells apart two replies that open with a short thought and make no call")
    func tellsApartTwoRepliesThatOpenWithAShortThoughtAndMakeNoCall() {
        let one = BuildActivity.build([.reasoning(text: "Easy one."), .text("4")], isStreaming: false)
        let two = BuildActivity.build([.reasoning(text: "Simple."), .text("5")], isStreaming: false)
        let again = BuildActivity.build([.reasoning(text: "Easy one."), .text("4")], isStreaming: false)
        guard let a = one.items.first?.key, let b = two.items.first?.key else {
            Issue.record("expected a thought row in each"); return
        }
        #expect(a != b)
        #expect(again.items.first?.key == a)
        #expect(BuildActivity.rowIdentity(a) == "thought@0")
    }

    // MARK: - rowIdentity

    @Test("drops the reply's anchor from the steps keyed by place")
    func dropsTheRepliesAnchorFromTheStepsKeyedByPlace() {
        #expect(BuildActivity.rowIdentity("thought:h1abc:0") == "thought@0")
        #expect(BuildActivity.rowIdentity("note:toolu_01:12") == "note@12")
        #expect(BuildActivity.rowIdentity("plan:h9:3") == "plan@3")
        #expect(BuildActivity.rowIdentity("image:h9:4") == "image@4")
    }

    @Test("keeps a key the anchor plays no part in")
    func keepsAKeyTheAnchorPlaysNoPartIn() {
        #expect(BuildActivity.rowIdentity("tool:toolu_01") == "tool:toolu_01")
        #expect(BuildActivity.rowIdentity("result:call-1:3") == "result:call-1:3")
        #expect(BuildActivity.rowIdentity("dpoll:call-2") == "dpoll:call-2")
    }

    // Adapted: a streaming thought is a `LiveTextRun` on iOS, which anchors the
    // reply by its run id rather than its text — so the two builds below (two
    // runs) get different anchors, as the web's growing text does.
    @Test("is the same while a short opening thought grows past the anchor's length")
    func isTheSameWhileAShortOpeningThoughtGrowsPastTheAnchorsLength() {
        let short = BuildActivity.build([.liveReasoning(LiveTextRun("Look"), streaming: true)],
                                        isStreaming: true, keepAnswer: true)
        let longer = BuildActivity.build(
            [.liveReasoning(LiveTextRun("Looking at the repository layout before anything else"), streaming: true)],
            isStreaming: true, keepAnswer: true)
        guard let a = short.items.first?.key, let b = longer.items.first?.key else {
            Issue.record("expected a thought row in each"); return
        }
        #expect(a != b)
        #expect(BuildActivity.rowIdentity(a) == BuildActivity.rowIdentity(b))
    }

    // The same, for settled reasoning, whose anchor is read from its text.
    @Test("is the same while a short opening thought grows past the anchor's length (settled text)")
    func isTheSameForSettledReasoning() {
        let short = BuildActivity.build([.reasoning(text: "Look")], isStreaming: false, keepAnswer: true)
        let longer = BuildActivity.build([.reasoning(text: "Looking at the repository layout before anything else")],
                                         isStreaming: false, keepAnswer: true)
        guard let a = short.items.first?.key, let b = longer.items.first?.key else {
            Issue.record("expected a thought row in each"); return
        }
        #expect(a != b)
        #expect(BuildActivity.rowIdentity(a) == BuildActivity.rowIdentity(b))
    }

    // MARK: - hasVisibleAnswer (web `hasVisibleAnswer`, exercised by the
    // adapter tests on the web)

    @Test("does not take whitespace-only settled text for an answer")
    func doesNotTakeWhitespaceOnlySettledTextForAnAnswer() {
        #expect(!BuildActivity.hasVisibleAnswer([.text("  \n ")]))
        #expect(BuildActivity.hasVisibleAnswer([.text("  \n "), .turnError("boom")]))
        #expect(BuildActivity.hasVisibleAnswer([.text("Done.")]))
    }
}
