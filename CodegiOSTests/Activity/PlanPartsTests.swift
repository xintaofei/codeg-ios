import Foundation
import Testing
@testable import Codeg

private func entry(_ content: String, _ status: String = "pending", _ priority: String = "medium") -> PlanEntry {
    PlanEntry(content: content, priority: priority, status: status)
}

/// Plan checklists read off calls — `src/lib/plan-parse.test.ts` (codeg 0.44)
/// and Android's `PlanPartsTest`.
struct PlanParseTests {
    @Test func aChecklistReadsFromACallsTodosEntriesOrPlan() {
        let entries = PlanParse.parseTodos(
            #"{"todos":[{"content":"Read the code","status":"done","priority":"urgent"},{"step":"Fix it","status":"running"},{"content":"  "}]}"#)
        #expect(entries == [entry("Read the code", "completed", "high"), entry("Fix it", "in_progress")])
        #expect(PlanParse.parseTodos(#"{"entries":[{"content":"A"}]}"#) == [entry("A")])
        #expect(PlanParse.parseTodos(#"{"plan":[{"step":"B","status":"done"}]}"#) == [entry("B", "completed")])
    }

    @Test func eachAgentsShapeReads() {
        // Claude Code's TodoWrite.
        #expect(PlanParse.parseTodos(
            #"{"todos":[{"content":"Run the tests","status":"in_progress","activeForm":"Running the tests"}]}"#)
            == [entry("Run the tests", "in_progress")])
        // codex's update_plan: its explanation is not an entry.
        #expect(PlanParse.parseTodos(
            #"{"explanation":"Two steps","plan":[{"step":"Ship","status":"pending"},{"step":"Tell","status":"completed"}]}"#)
            == [entry("Ship"), entry("Tell", "completed")])
        // Kimi Code's TodoList.
        #expect(PlanParse.parseTodos(#"{"todos":[{"title":"Verify changes","status":"done"}]}"#)
            == [entry("Verify changes", "completed")])
    }

    @Test func anEntryIsNamedByTheFirstStringItHolds() {
        #expect(PlanParse.parseTodos(#"{"todos":[{"title":"Titled"},{"name":"Named"},{"status":"pending"}]}"#)
            == [entry("Titled"), entry("Named")])
        // Even a blank one, as the web reads it: the entry names nothing.
        #expect(PlanParse.parseTodos(#"{"todos":[{"content":"","step":"Ignored"}]}"#).isEmpty)
        // A name that isn't a string doesn't count.
        #expect(PlanParse.parseTodos(#"{"todos":[{"content":7,"step":"Seven"}]}"#) == [entry("Seven")])
        // A list that names nothing gives way to the next.
        #expect(PlanParse.parseTodos(#"{"todos":[],"plan":[{"step":"Next"}]}"#) == [entry("Next")])
    }

    @Test func aDocumentOrAnythingElseIsNoChecklist() {
        // ExitPlanMode's plan is a document, not a checklist.
        #expect(PlanParse.parseTodos(##"{"plan":"# The plan"}"##).isEmpty)
        #expect(PlanParse.parseTodos("not json").isEmpty)
        #expect(PlanParse.parseTodos(#"{"other":1}"#).isEmpty)
        #expect(PlanParse.parseTodos(#"[{"content":"A"}]"#).isEmpty)
        #expect(PlanParse.parseTodos("").isEmpty)
        #expect(PlanParse.parseTodos(nil).isEmpty)
    }

    @Test func statusesAndPrioritiesNormalize() {
        let statuses: [(String?, String)] = [
            ("completed", "completed"), ("done", "completed"), (" DONE ", "completed"),
            ("in_progress", "in_progress"), ("in-progress", "in_progress"), ("in progress", "in_progress"),
            ("running", "in_progress"), ("active", "in_progress"),
            ("pending", "pending"), ("whatever", "pending"), (nil, "pending"),
        ]
        for (raw, normalized) in statuses {
            #expect(PlanParse.normalizeStatus(raw) == normalized)
        }
        let priorities: [(String?, String)] = [
            ("high", "high"), ("urgent", "high"), ("low", "low"), ("medium", "medium"),
            ("nonsense", "medium"), (nil, "medium"),
        ]
        for (raw, normalized) in priorities {
            #expect(PlanParse.normalizePriority(raw) == normalized)
        }
    }

    @Test func planLikeNamesAreTodoWriteKimisTodoListAndAnythingNamingAPlan() {
        for name in ["TodoWrite", "todo_write", "TodoList", "todo_list", "update_plan", "exit_plan_mode", "plan_review"] {
            #expect(PlanParse.isPlanLikeToolName(name))
        }
        // iOS's task checklist is not a plan.
        for name in ["Bash", "read_file", "Read", "TaskCreate", "TaskList", "TaskUpdate"] {
            #expect(!PlanParse.isPlanLikeToolName(name))
        }
    }

    @Test func whatAHandOffWritesReadsBackTheSame() {
        let entries = [entry("Read the code", "completed", "high"), entry("Fix \"it\"", "in_progress"),
                       entry("Ship / tell", "pending", "low")]
        #expect(PlanParse.parseTodos(PlanParse.handoffInput(entries)) == entries)
        // The same plan always writes the same text (the folded turn is a cache key).
        #expect(PlanParse.handoffInput(entries) == PlanParse.handoffInput(entries))
    }

    // web `kimiTodoWriteEntries`
    @Test func aKimiTodoWriteIsKnownByItsExactShape() {
        #expect(PlanParse.kimiTodoWriteEntries(
            #"{"todos":[{"title":"Confirm 401 behavior","status":"in_progress"},{"title":"Unify request.js","status":"pending"},{"title":"Verify changes","status":"done"}]}"#)
            == [entry("Confirm 401 behavior", "in_progress"), entry("Unify request.js"), entry("Verify changes", "completed")])
        // Its status is matched case-insensitively.
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[{"title":"X","status":"IN_PROGRESS"}]}"#)
            == [entry("X", "in_progress")])
        // The read and clear forms carry no plan.
        #expect(PlanParse.kimiTodoWriteEntries("{}") == nil)
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[]}"#) == nil)
        // Not Kimi's shape: other lists, other names, no status, another status, a blank title.
        #expect(PlanParse.kimiTodoWriteEntries(#"{"entries":[{"content":"A"}]}"#) == nil)
        #expect(PlanParse.kimiTodoWriteEntries(#"{"plan":[{"step":"B"}]}"#) == nil)
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[{"name":"X","status":"pending"}]}"#) == nil)
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[{"title":"X"}]}"#) == nil)
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[{"title":"X","status":"weird"}]}"#) == nil)
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[{"title":"   ","status":"pending"}]}"#) == nil)
        // Claude's TodoWrite names its entries `content`: not a Kimi write.
        #expect(PlanParse.kimiTodoWriteEntries(#"{"todos":[{"content":"X","status":"pending"}]}"#) == nil)
        for junk in ["not json", "5", #""a string""#, ""] {
            #expect(PlanParse.kimiTodoWriteEntries(junk) == nil)
        }
        #expect(PlanParse.kimiTodoWriteEntries(nil) == nil)
    }

    // web `extractPlanMarkdown`
    @Test func aPlanModeDocumentIsReadDirectlyOrOneLevelIn() {
        #expect(PlanParse.planMarkdown(##"{"plan":"# Title\n- a"}"##) == "# Title\n- a")
        #expect(PlanParse.planMarkdown(#"{"Plan":"do x"}"#) == "do x")
        #expect(PlanParse.planMarkdown(#"{"rawInput":{"plan":"nested"}}"#) == "nested")
        #expect(PlanParse.planMarkdown(#"{"raw_input":{"Plan":"nested2"}}"#) == "nested2")
        #expect(PlanParse.planMarkdown("{}") == nil)
        #expect(PlanParse.planMarkdown(#"{"plan":"   "}"#) == nil)
        #expect(PlanParse.planMarkdown(#"{"plan":42}"#) == nil)
        #expect(PlanParse.planMarkdown(#"{"rawInput":{"other":"x"}}"#) == nil)
        // A checklist is not a document.
        #expect(PlanParse.planMarkdown(#"{"plan":[{"step":"A"}]}"#) == nil)
        #expect(PlanParse.planMarkdown(nil) == nil)
    }
}

/// Where a plan stands in a reply — live, handed off, and in history — and
/// that it is the same card and row in each.
@MainActor
struct PlanPlacementTests {
    private let date = Date(timeIntervalSince1970: 1_792_000_000)
    private let agent = AgentType.claudeCode

    private func assistant(_ id: String, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: blocks, timestamp: date)
    }

    private func user(_ id: String, _ text: String) -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text(text)], timestamp: date)
    }

    private func kinds(_ parts: [RenderPart]) -> [String] {
        parts.map { part in
            switch part {
            case .plan: return "plan"
            case .tool: return "tool"
            case .text, .liveText: return "text"
            case .taskGroup: return "task-group"
            default: return "other"
            }
        }
    }

    private struct PlanNode: Equatable {
        let id: String
        let entries: [PlanEntry]
        let streaming: Bool
    }

    private func plans(_ nodes: [TimelineNode]) -> [PlanNode] {
        nodes.compactMap { node -> PlanNode? in
            guard case .plan(let entries, let streaming) = node.content else { return nil }
            return PlanNode(id: node.id, entries: entries, streaming: streaming)
        }
    }

    private func texts(_ live: LiveTurn) -> [String] {
        live.segments.compactMap { segment -> String? in
            if case .text(let run) = segment { return run.fullText }
            return nil
        }
    }

    private func isPlan(_ segment: LiveSegment?) -> Bool {
        if case .plan? = segment { return true }
        return false
    }

    // MARK: History

    @Test func aPersistedPlanCallDrawsAsThePlanItsResultConsumed() {
        let parts = MessageRender.adaptTurn(assistant("plan-a1", [
            .toolUse(id: "t1", name: "TodoWrite", inputPreview: #"{"todos":[{"content":"A","status":"pending"}]}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "t1", outputPreview: "Todos have been modified successfully", isError: false, agentStats: nil),
            .toolUse(id: "t2", name: "TodoWrite", inputPreview: #"{"todos":[]}"#, status: .unknown, meta: nil),
            .toolResult(id: "t2", outputPreview: "ok", isError: false, agentStats: nil),
        ]))
        // No orphan result after the plan; one with nothing to show stays a call.
        #expect(kinds(parts) == ["plan", "tool"])
        guard case .plan(let id, let entries, let streaming) = parts[0] else {
            Issue.record("expected a plan"); return
        }
        #expect(id == "t1")
        #expect(entries == [entry("A")])
        #expect(streaming == false)
        // Neither the plan nor a todo call is a step of the header's, and the
        // plan is process, not the answer.
        #expect(BuildActivity.build(parts, isStreaming: false).summary.steps == 0)
        #expect(!BuildActivity.isAnswerPart(parts[0]))
    }

    @Test func codexsUpdatePlanAndKimisTodoListDrawAsPlansToo() {
        let parts = MessageRender.adaptTurn(assistant("plan-a2", [
            .toolUse(id: "p1", name: "update_plan",
                     inputPreview: #"{"explanation":"x","plan":[{"step":"Ship","status":"in_progress"}]}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "p1", outputPreview: "Plan updated", isError: false, agentStats: nil),
            .toolUse(id: "k1", name: "TodoList", inputPreview: #"{"todos":[{"title":"Verify","status":"done"}]}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "k1", outputPreview: "ok", isError: false, agentStats: nil),
            // Kimi's read form has nothing to show: it stays a call.
            .toolUse(id: "k2", name: "TodoList", inputPreview: "{}", status: .unknown, meta: nil),
            .toolResult(id: "k2", outputPreview: "[]", isError: false, agentStats: nil),
        ]))
        #expect(kinds(parts) == ["plan", "plan", "tool"])
        if case .plan(_, let entries, _) = parts[1] { #expect(entries == [entry("Verify", "completed")]) }
    }

    @Test func aWriteThatFailedKeepsItsErrorCard() {
        let parts = MessageRender.adaptTurn(assistant("plan-a3", [
            .toolUse(id: "f1", name: "TodoWrite", inputPreview: #"{"todos":[{"content":"A"}]}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "f1", outputPreview: "InputValidationError", isError: true, agentStats: nil),
        ]))
        #expect(kinds(parts) == ["tool"])
        if case .tool(let vm) = parts[0] { #expect(vm.isError) }
    }

    @Test func aNameThatMerelyHoldsTheLettersStaysACall() {
        #expect(PlanParse.isPlanLikeToolName("mcp__travel__book_airplane"))
        let parts = MessageRender.adaptTurn(assistant("plan-a4", [
            .toolUse(id: "x1", name: "mcp__travel__book_airplane", inputPreview: #"{"seat":"window"}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "x1", outputPreview: "ok", isError: false, agentStats: nil),
        ]))
        #expect(kinds(parts) == ["tool"])
    }

    @Test func theTaskChecklistIsLeftAsItWas() {
        let parts = MessageRender.adaptTurn(assistant("plan-a5", [
            .toolUse(id: "c1", name: "TaskCreate", inputPreview: #"{"subject":"Write tests","description":"d"}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "c1", outputPreview: "Task #1 created", isError: false, agentStats: nil),
        ]))
        #expect(kinds(parts) == ["task-group"])
    }

    @Test func aPersistedPlanIsAStepOfItsReplyKeyedByItsCall() {
        let turns = [
            user("u1", "plan it"),
            assistant("plan-a6", [
                .text("Let me lay the work out before I start on it."),
                .toolUse(id: "t1", name: "TodoWrite", inputPreview: #"{"todos":[{"content":"A","status":"in_progress"}]}"#,
                         status: .unknown, meta: nil),
                .toolResult(id: "t1", outputPreview: "ok", isError: false, agentStats: nil),
                .toolUse(id: "r1", name: "Read", inputPreview: #"{"file_path":"/r/a.ts"}"#, status: .unknown, meta: nil),
                .toolResult(id: "r1", outputPreview: "x", isError: false, agentStats: nil),
                .text("Done."),
            ]),
        ]
        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: agent, suppressInFlight: false)
        #expect(plans(nodes) == [PlanNode(id: "tool-t1", entries: [entry("A", "in_progress")], streaming: false)])
        let node = nodes.first { $0.id == "tool-t1" }
        #expect(node?.reply?.role == .body, "a plan is process: it folds with the reply")
        if case .plan? = node?.marker {} else { Issue.record("the plan wears the plan marker") }
    }

    @Test func aPlanModeCallCarriesItsDocumentForItsCard() {
        let exit = ToolCallVM(id: "e1", rawName: "ExitPlanMode", kind: "", state: .done,
                              input: ##"{"plan":"# Plan\n- a"}"##, output: nil, content: nil, isError: false)
        #expect(exit.planDocument == "# Plan\n- a")
        let todo = ToolCallVM(id: "t1", rawName: "TodoWrite", kind: "", state: .done,
                              input: #"{"todos":[]}"#, output: nil, content: nil, isError: false)
        #expect(todo.planDocument == nil)
        // And it stays a call: a document is not a checklist.
        let parts = MessageRender.adaptTurn(assistant("plan-a7", [
            .toolUse(id: "e1", name: "ExitPlanMode", inputPreview: ##"{"plan":"# Plan\n- a"}"##,
                     status: .unknown, meta: nil),
            .toolResult(id: "e1", outputPreview: "User has approved your plan.", isError: false, agentStats: nil),
        ]))
        #expect(kinds(parts) == ["tool"])
    }

    // MARK: Live

    @Test func theLivePlanStandsWhereTheAgentLastRevisedIt() throws {
        let live = LiveTurn(id: "live-1")
        live.updatePlan([entry("A")])
        live.appendText("working on it")
        live.updatePlan([entry("A", "completed")])
        #expect(live.segments.count == 2)
        #expect(isPlan(live.segments.last))
        let nodes = TranscriptTimeline.buildLive(live, agent: agent)
        #expect(plans(nodes) == [PlanNode(id: "tool-live-1-plan", entries: [entry("A", "completed")], streaming: true)])
        let proseIndex = nodes.firstIndex(where: { node in
            if case .liveText = node.content { return true }
            return false
        })
        let planIndex = nodes.firstIndex(where: { $0.id == "tool-live-1-plan" })
        let prose = try #require(proseIndex)
        let plan = try #require(planIndex)
        #expect(prose < plan, "revised after the prose, it stands after it")
        // An empty plan takes it away.
        live.updatePlan([])
        #expect(live.currentPlan == nil)
        #expect(plans(TranscriptTimeline.buildLive(live, agent: agent)).isEmpty)
    }

    @Test func aPlanAloneIsWhatTheReplyHasSoFar() {
        let live = LiveTurn(id: "live-2")
        live.updatePlan([entry("A")])
        #expect(!live.isEmpty)
        let nodes = TranscriptTimeline.buildLive(live, agent: agent)
        #expect(plans(nodes).map(\.id) == ["tool-live-2-plan"])
        #expect(!nodes.contains { if case .thinking = $0.content { return true }; return false })
    }

    @Test func proseThePlanCutInTwoIsOneAgainOnceItMovesOn() {
        let live = LiveTurn(id: "live-3")
        live.appendText("Hello wor")
        live.updatePlan([entry("A")])
        live.appendText("ld, done.")
        live.updatePlan([entry("A", "completed")])
        #expect(texts(live) == ["Hello world, done."])
        #expect(live.segments.count == 2)
        #expect(isPlan(live.segments.last))
        // Published at once, not a coalesce window later.
        guard case .text(let run)? = live.segments.first else { Issue.record("prose first"); return }
        #expect(run.text == "Hello world, done.")
        // The next words start a run of their own, after the plan.
        live.appendText(" Next.")
        #expect(texts(live) == ["Hello world, done.", " Next."])
    }

    @Test func thoughtThePlanCutInTwoIsOneAgainButNotAcrossKinds() {
        let live = LiveTurn(id: "live-4")
        live.appendThinking("Think")
        live.updatePlan([entry("A")])
        live.appendThinking("ing on")
        live.updatePlan([entry("A")])   // the same plan, no longer last: it still moves
        let thoughts = live.segments.compactMap { segment -> String? in
            if case .thinking(let run) = segment { return run.fullText }
            return nil
        }
        #expect(thoughts == ["Thinking on"])
        #expect(isPlan(live.segments.last))

        let mixed = LiveTurn(id: "live-5")
        mixed.appendThinking("Thought")
        mixed.updatePlan([entry("A")])
        mixed.appendText("Prose")
        mixed.updatePlan([entry("B")])
        #expect(mixed.segments.count == 3, "a thought and prose are two runs either way")
        #expect(isPlan(mixed.segments.last))
    }

    @Test func aPlanRevisedAfterASteerMovesIntoTheReplyToIt() throws {
        let live = LiveTurn(id: "live-6")
        live.appendText("Before")
        live.updatePlan([entry("A")])
        live.insertSteering(SteeredMessage(id: "n1", text: "use tabs", at: date))
        live.appendText("After")
        live.updatePlan([entry("A", "completed")])
        // Not joined across the note.
        #expect(texts(live) == ["Before", "After"])
        let nodes = TranscriptTimeline.buildLive(live, agent: agent)
        let steerIndex = nodes.firstIndex(where: { $0.id == "steer-n1" })
        let planIndex = nodes.firstIndex(where: { $0.id == "tool-live-6-plan" })
        let steer = try #require(steerIndex)
        let plan = try #require(planIndex)
        #expect(steer < plan)
        #expect(plans(nodes).count == 1)
    }

    @Test func aReattachKeepsThePlan() {
        let rebuilt = LiveTurn(id: "rebuilt")
        rebuilt.appendText("so far")
        rebuilt.updatePlan([entry("A")])
        let live = LiveTurn(id: "live-7")
        live.adoptContent(from: rebuilt)
        #expect(live.currentPlan == [entry("A")])
        // Keyed by the turn that kept it, not the one it came from.
        #expect(plans(TranscriptTimeline.buildLive(live, agent: agent)).map(\.id) == ["tool-live-7-plan"])
    }

    // MARK: Hand-off

    @Test func aTurnHandedOffKeepsItsPlanInPlaceAsTheSameRow() throws {
        let live = LiveTurn(id: "live-8")
        live.appendText("first")
        live.updatePlan([entry("Step one")])
        live.appendText("then")
        live.isStreaming = false
        live.flushAllText()
        let liveNodes = TranscriptTimeline.buildLive(live, agent: agent)
        let snapshot = live.snapshotAsMessageTurns()
        let handed = TranscriptTimeline.buildPersisted(turns: [user("u1", "q")] + snapshot, pending: [],
                                                       agent: agent, suppressInFlight: false)
        #expect(plans(handed) == [PlanNode(id: "tool-live-8-plan", entries: [entry("Step one")], streaming: false)])
        #expect(plans(liveNodes) == plans(handed), "the same card, in the same row")
        // In place: between the two runs of prose, as the TodoWrite call the
        // transcript records a plan by.
        let blocks = try #require(snapshot.first).blocks
        #expect(blocks.count == 3)
        guard case .toolUse(let id, let name, _, _, _) = blocks[1] else {
            Issue.record("the plan is kept as a call"); return
        }
        #expect(id == live.planCallID)
        #expect(name == PlanParse.handoffToolName)
    }

    @Test func kimisTodoWriteIsDrawnAsThePlanUntilItsOwnPlanLands() {
        let input = #"{"todos":[{"title":"Confirm","status":"in_progress"},{"title":"Verify","status":"pending"}]}"#
        let live = LiveTurn(id: "live-9")
        live.upsertToolCall(id: "k1", title: "Updating todo list", kind: "other", status: "completed",
                            rawInput: input, rawOutput: "ok", content: nil)
        func isCall(_ node: TimelineNode) -> Bool {
            switch node.content {
            case .tool, .activityTool, .activityGroup: return true
            default: return false
            }
        }
        // Before its plan update lands, the write is the plan, never a call.
        var nodes = TranscriptTimeline.buildLive(live, agent: .kimiCode)
        #expect(plans(nodes).map(\.id) == ["tool-k1"])
        #expect(!nodes.contains(where: isCall))
        // Handed off like that, it keeps that row.
        live.isStreaming = false
        let early = TranscriptTimeline.buildPersisted(turns: [user("u1", "q")] + live.snapshotAsMessageTurns(),
                                                      pending: [], agent: .kimiCode, suppressInFlight: false)
        #expect(plans(early).map(\.id) == ["tool-k1"])
        // Once it lands, the plan stands for every write — live and handed off.
        live.isStreaming = true
        live.updatePlan([entry("Confirm", "in_progress"), entry("Verify")])
        nodes = TranscriptTimeline.buildLive(live, agent: .kimiCode)
        #expect(plans(nodes).map(\.id) == ["tool-live-9-plan"])
        #expect(!nodes.contains(where: isCall))
        live.isStreaming = false
        let blocks = live.snapshotAsMessageTurns().first?.blocks ?? []
        #expect(blocks.count == 1)
        if case .toolUse(let id, _, _, _, _)? = blocks.first { #expect(id == live.planCallID) }
    }
}
