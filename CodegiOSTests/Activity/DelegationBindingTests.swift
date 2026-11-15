import Foundation
import Testing
@testable import Codeg

// A delegation's card and rail marker, read against the connection's live
// binding (web `useDelegationCardModel`, `isAffirmedResume`, `taskEnding`;
// Android `Delegations.model` / `resumedBinding`), and the rail's markers for
// the agent's words and its delegations.

private typealias D = DelegationModel

private func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

private let taskId = "b0858712-9257-45a1-850e-c80e75291939"

private func delegate(id: String = "call-1", input: String? = #"{"agent_type":"codex","task":"Fix the build"}"#,
                      output: String? = nil, state: ToolCallState = .done, isError: Bool = false,
                      meta: AnyJSON? = nil) -> ToolCallVM {
    ToolCallVM(id: id, rawName: "mcp__codeg-mcp__delegate_to_agent", kind: "", state: state,
               input: input, output: output, content: nil, isError: isError, meta: meta)
}

private func resume(id: String = "call-9", output: String?, reason: String = "it was killed") -> ToolCallVM {
    ToolCallVM(id: id, rawName: "mcp__codeg-mcp__resume_delegation", kind: "", state: .done,
               input: json(["task_id": taskId, "reason": reason]), output: output, content: nil, isError: false)
}

private func poll(id: String, _ report: [String: Any]) -> ToolCallVM {
    ToolCallVM(id: id, rawName: "mcp__codeg-mcp__get_delegation_status", kind: "", state: .done,
               input: json(["task_ids": [taskId]]), output: json(["structuredContent": report]),
               content: nil, isError: false)
}

private func binding(parent: String = "call-1", child: Int = 42, agent: AgentType = .codex,
                     status: DelegationBinding.Status = .running, errorCode: String? = nil,
                     assistant: String? = nil) -> DelegationBinding {
    DelegationBinding(info: DelegationInfo(parentToolUseId: parent, childConnectionId: "child-conn",
                                           childConversationId: child, agentType: agent,
                                           taskPreview: "Fix the build (preview)", taskId: taskId,
                                           assistantId: assistant == nil ? nil : 3, assistantName: assistant),
                      status: status, errorCode: errorCode)
}

/// An MCP result: the report, and the line a host renders of it.
private func result(_ report: [String: Any], text: String = "ok") -> String {
    json(["content": [["type": "text", "text": text]], "structuredContent": report])
}

private let ack = result(["task_id": taskId, "status": "running"],
                         text: "Delegation started. task_id=\(taskId). Call get_delegation_status with this id.")

@MainActor
@Suite("a delegation's card")
struct DelegationCardModelTests {
    @Test func theLiveBindingSaysHowItStands() {
        let call = delegate(output: ack)
        #expect(D.card(call, binding: nil, later: nil)?.status == .running, "the ack alone runs")
        let done = D.card(call, binding: binding(status: .ok), later: nil)
        #expect(done?.status == .ok)
        #expect(done?.childConversationId == 42)
        let failed = D.card(call, binding: binding(status: .err, errorCode: "timeout"), later: nil)
        #expect(failed?.status == .err)
        #expect(failed?.errorCode == "timeout")
    }

    @Test func aReturningScreenTrustsTheStampOverABindingThatEndedUnheard() throws {
        // Started while the screen watched; finished while it was away; the
        // reattach snapshot no longer lists it, and the reload stamped the call.
        let runs = ConnectionRunsModel()
        let snap0 = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: JSONSerialization.data(
            withJSONObject: ["connection_id": "c1", "status": "connected", "event_seq": 1]))
        runs.hydrate(snap0, connection: "c1")
        runs.apply(.delegationStarted(binding().info), seq: 2)
        let snap1 = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: JSONSerialization.data(
            withJSONObject: ["connection_id": "c1", "status": "connected", "event_seq": 9]))
        runs.hydrate(snap1, connection: "c1")
        let meta = AnyJSON.object(["codeg.delegation": .object([
            "status": .string("failed"), "error_code": .string("timeout"), "duration_ms": .number(30_000),
        ])])
        let call = delegate(output: ack, meta: meta)
        let card = D.card(call, binding: D.binding(for: call, in: runs.delegationBindings), later: nil)
        #expect(card?.status == .err)
        #expect(card?.errorCode == "timeout")
    }

    @Test func theBrokersStampStandsInOnceTheBindingIsGone() {
        let meta = AnyJSON.object(["codeg.delegation": .object([
            "status": .string("completed"), "duration_ms": .number(94_000),
            "child_conversation_id": .number(7), "agent_type": .string("gemini"),
        ])])
        let card = D.card(delegate(input: "{}", output: ack, meta: meta), binding: nil, later: nil)
        #expect(card?.status == .ok)
        #expect(card?.durationMs == 94_000)
        #expect(card?.childConversationId == 7)
        // The call's arguments named no agent: the stamp's is the one.
        #expect(card?.agentType == .gemini)
    }

    @Test func aLaterCheckEndsIt() {
        let checks = [poll(id: "p1", ["task_id": taskId, "status": "running"]),
                      poll(id: "p2", ["task_id": taskId, "status": "completed", "text": "## Fixed\nAll green.",
                                      "duration_ms": 61_000, "progress": ["steps": 12, "last_step": "Ran tests"]])]
        let later = D.latestTaskRow(checks, taskId: taskId)
        let card = D.card(delegate(output: ack), binding: nil, later: later)
        #expect(card?.status == .ok)
        #expect(card?.outcome == "## Fixed\nAll green.")
        #expect(card?.durationMs == 61_000)
        #expect(card?.progress == DelegationProgress(steps: 12, lastStep: "Ran tests"))
        #expect(D.previewLine(card?.outcome) == "Fixed")
        // The binding is fresher than any check.
        #expect(D.card(delegate(output: ack), binding: binding(status: .running), later: later)?.status == .running)
    }

    @Test func aCheckThatFoundItParkedOnTheUserWaits() {
        let blocked = poll(id: "p1", ["task_id": taskId, "status": "running",
                                      "blocked_on": ["kind": "permission"]])
        let later = D.latestTaskRow([blocked], taskId: taskId)
        #expect(later?.badge.status == .waiting)
        #expect(D.card(delegate(output: ack), binding: nil, later: later)?.status == .waiting)
        // A text-only host: the backend's blocked note.
        let text = D.parseStatusReport(output: "Running.\nAwaiting your decision: allow npm test?", errorText: nil)
        #expect(text.status == .running)
        #expect(text.blocked)
    }

    @Test func aCallNamingAnAssistantIsNotPaintedWithItsAgentArgument() {
        let call = delegate(input: #"{"assistant_id":3,"agent_type":"codex","task":"Review"}"#, output: ack)
        #expect(D.card(call, binding: nil, later: nil)?.agentType == nil)
        let bound = D.card(call, binding: binding(agent: .claudeCode, assistant: "Reviewer"), later: nil)
        #expect(bound?.agentType == .claudeCode)
        #expect(bound?.assistantName == "Reviewer")
    }

    @Test func theTaskComesFromTheArgumentsThenTheBinding() {
        #expect(D.card(delegate(output: ack), binding: binding(), later: nil)?.task == "Fix the build")
        // Cursor's announcements carry no arguments.
        #expect(D.card(delegate(input: "{}", output: ack), binding: binding(), later: nil)?.task
                == "Fix the build (preview)")
        #expect(D.card(delegate(output: ack), binding: nil, later: nil)?.taskId == taskId)
    }

    @Test func aHostsBareAckIsStillAnAck() {
        // codex's history parser writes the code-mode delegation's result as
        // this line; it is the ack, never the task's result.
        let bare = "Delegation successful. task_id=task-b. child_conversation_id=901."
        let card = D.card(delegate(output: bare), binding: nil, later: nil)
        #expect(card?.status == .running)
        #expect(card?.outcome == nil)
        #expect(card?.taskId == "task-b")
        #expect(card?.childConversationId == 901)
        #expect(D.resolveStatus(parsedMeta: nil, toolOutput: D.parseToolOutput(bare), state: .done,
                                hasError: false) == .running)
    }

    @Test func nothingToDrawItByIsNoCard() {
        #expect(D.card(delegate(input: "{}", output: nil, state: .running), binding: nil, later: nil) == nil)
    }

    @Test func aResumeIsTheSameCardMarkedResumed() {
        let card = D.card(resume(output: result([
            "task_id": taskId, "status": "running", "agent_type": "codex", "child_conversation_id": 42,
            "message": "Delegation resumed. task_id=\(taskId) (unchanged).",
        ])), binding: nil, later: nil)
        #expect(card?.resumed == true)
        #expect(card?.agentType == .codex)
        #expect(card?.status == .running)
        #expect(card?.reason == "it was killed")
        #expect(card?.taskId == taskId)
    }

    @Test func aRefusedResumeIsNoCard() {
        let refused = resume(output: result([
            "task_id": taskId, "status": "completed", "error_code": "not_resumable", "agent_type": "codex",
            "child_conversation_id": 42, "message": "Not resumed: the task already completed.",
        ], text: "Not resumed: the task already completed."))
        #expect(D.card(refused, binding: binding(), later: nil) == nil)
    }
}

@MainActor
@Suite("finding a resume's binding")
struct DelegationResumeBindingTests {
    @Test func aDelegateIsFoundByItsOwnId() {
        let b = binding(parent: "call-1")
        #expect(D.binding(for: delegate(id: "call-1"), in: [b]) == b)
        #expect(D.binding(for: delegate(id: "call-2"), in: [b]) == nil)
    }

    @Test func aResumeIsFoundByItsTaskWhenTheResultNamesTheSameChild() {
        let b = binding(parent: "call-1", child: 42)
        let same = resume(output: result(["task_id": taskId, "status": "running", "child_conversation_id": 42]))
        #expect(D.binding(for: same, in: [b]) == b)
        let other = resume(output: result(["task_id": taskId, "status": "running", "child_conversation_id": 99]))
        #expect(D.binding(for: other, in: [b]) == nil)
    }

    @Test func onAStructureDroppingHostTheAckAffirmsIt() {
        let b = binding(parent: "call-1")
        #expect(D.binding(for: resume(output: "Delegation resumed. task_id=\(taskId) (unchanged)."), in: [b]) == b)
        #expect(D.binding(for: resume(output: "Unknown task id — it never existed."), in: [b]) == nil)
        #expect(D.binding(for: resume(output: nil), in: [b]) == nil)
    }
}

// `delegation-card.test.ts` › the `isAffirmedResume` halves of the resume verdict suites.
@Suite("resume verdicts: affirmed")
struct DelegationAffirmedResumeTests {
    private let refusalText = "Not resumed: the task already completed — resume only applies to a canceled task."
    private let ackText = "Delegation resumed. task_id=t-1 (unchanged). Call get_delegation_status with this id."
    private let unknownText = "Unknown task id — it never existed, isn't owned by this session, or its result was evicted."
    private let childProse = "I reviewed the resume path. The broker answers `Not resumed: <why>` when it "
        + "refuses, and `Delegation resumed. task_id=…` when it succeeds."

    @Test func affirmsAResumeFromTheAckTextAlone() {
        #expect(D.isAffirmedResume(output: ackText, errorText: nil))
    }

    @Test func doesNotAffirmAnUnknownTaskReportOrARefusal() {
        #expect(!D.isAffirmedResume(output: unknownText, errorText: nil))
        #expect(!D.isAffirmedResume(output: refusalText, errorText: nil))
        #expect(!D.isAffirmedResume(output: nil, errorText: nil))
    }

    @Test func keepsTheStructuredVerdictAuthoritativeWhenItSurvived() {
        let structured = json(["task_id": "t-1", "status": "running", "agent_type": "codex",
                               "child_conversation_id": 9, "message": ackText])
        #expect(D.isAffirmedResume(output: structured, errorText: nil))
    }

    @Test func ignoresTheMarkersInsideACompletedChildsText() {
        let structured = json(["task_id": "t-1", "status": "completed", "agent_type": "codex",
                               "child_conversation_id": 9, "text": childProse])
        #expect(D.isAffirmedResume(output: structured, errorText: nil))
        #expect(!D.isAffirmedResume(output: childProse, errorText: nil))
    }

    @Test func doesNotAffirmAStructuredReportThatNamedNoChild() {
        let unknown = json(["task_id": "t-1", "status": "unknown", "message": "Unknown task id — it never existed."])
        #expect(!D.isAffirmedResume(output: unknown, errorText: nil))
    }

    @Test func treatsTheLegacyKindShapedOutcomeAsStructured() {
        let legacyOk = json(["kind": "ok", "child_conversation_id": 9,
                             "text": "Not resumed: is the phrase the broker uses when it declines."])
        #expect(D.isAffirmedResume(output: legacyOk, errorText: nil))
        let legacyErr = json(["kind": "err", "code": "spawn_failed",
                              "message": "Delegation resumed is the phrase used on success."])
        #expect(!D.isAffirmedResume(output: legacyErr, errorText: nil))
    }
}

@MainActor
@Suite("the rail's markers")
struct TimelineMarkerTests {
    @Test func theAgentsWordsAreADot() {
        let node = TimelineNode(id: "n", content: .assistantText("Hello"), agent: .claudeCode)
        guard case .prose = node.marker else { Issue.record("got \(node.marker)"); return }
    }

    @Test func aReplyHeaderKeepsTheSessionsAgent() {
        let header = TimelineNode.ReplyHeader(replyKey: "r", summary: ActivitySummary(), completed: true,
                                              foldable: false, hasSteps: true, durationMs: nil)
        let node = TimelineNode(id: "h", content: .replyHeader(header), agent: .codex)
        guard case .assistant(.codex) = node.marker else { Issue.record("got \(node.marker)"); return }
    }

    @Test func aDelegationIsDrawnAsTheAgentThatTookIt() {
        let node = TimelineNode(id: "d", content: .delegation(delegate(output: ack), later: nil), agent: .claudeCode)
        guard case .delegation(let vm, _) = node.marker else { Issue.record("got \(node.marker)"); return }
        #expect(vm.id == "call-1")
        let checks = TimelineNode(id: "c", content: .delegationStatusGroup([poll(id: "p", ["task_id": taskId,
                                                                                           "status": "running"])]),
                                  agent: .claudeCode)
        guard case .delegationChecks(_, cancel: false) = checks.marker else { Issue.record("got \(checks.marker)"); return }
    }

    @Test func theChecksStandWhereTheirTasksDo() {
        #expect(D.checksStatus([poll(id: "p", ["task_id": taskId, "status": "completed"])], kind: .status) == .ok)
        #expect(D.checksStatus([poll(id: "p", ["task_id": taskId, "status": "failed"])], kind: .status) == .err)
        #expect(D.checksStatus([poll(id: "p", ["task_id": taskId, "status": "running",
                                               "blocked_on": ["kind": "question"]])], kind: .status) == .waiting)
        // Came back "still running": a settled snapshot, not live work.
        #expect(D.checksStatus([poll(id: "p", ["task_id": taskId, "status": "running"])], kind: .status) == .ok)
    }

    @Test func aDelegateCallInAReplyBecomesADelegationNode() {
        let call = delegate(output: ack)
        let check = poll(id: "p2", ["task_id": taskId, "status": "completed", "text": "done"])
        let turn = MessageTurn(id: "a1", role: .assistant, blocks: [
            .toolUse(id: call.id, name: call.rawName, inputPreview: call.input, status: .unknown, meta: nil),
            .toolResult(id: call.id, outputPreview: ack, isError: false, agentStats: nil),
            .toolUse(id: check.id, name: check.rawName, inputPreview: check.input, status: .unknown, meta: nil),
            .toolResult(id: check.id, outputPreview: check.output, isError: false, agentStats: nil),
            .text("All done."),
        ], timestamp: Date(timeIntervalSince1970: 0))
        let nodes = TranscriptTimeline.buildPersisted(turns: [turn], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false)
        let delegation = nodes.compactMap { node -> DelegationTaskRow?? in
            if case .delegation(_, let later) = node.content { return .some(later) }
            return nil
        }
        #expect(delegation.count == 1)
        #expect(delegation.first??.report.status == .completed, "the later check is handed over")
    }
}
