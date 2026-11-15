import Foundation
import Testing
@testable import Codeg

/// The reply builder + fold pass together: what a folded or unfolded reply
/// actually puts on screen.
@MainActor
struct TimelineFoldingTests {
    private func visible(_ nodes: [TimelineNode], store: ReplyFoldStore) -> [TimelineNode] {
        ReplyFolding.apply(nodes, store: store)
    }

    private func liveReplyWithAnswer() -> LiveTurn {
        let live = LiveTurn()
        live.upsertToolCall(id: "c1", title: "Read", kind: "read", status: "completed",
                            rawInput: #"{"file_path":"/r/a.ts"}"#, rawOutput: "x", content: nil)
        live.appendText("The answer so far")
        return live
    }

    private func hasLiveText(_ nodes: [TimelineNode]) -> Bool {
        nodes.contains { if case .liveText = $0.content { return true }; return false }
    }

    @Test func aFoldedLiveReplyKeepsItsStreamingAnswerInView() {
        let live = liveReplyWithAnswer()
        let store = ReplyFoldStore()
        store.beginRound()
        store.setOpen(false, key: live.id, isCurrent: true)
        let open = store.isOpen(live.id, isCurrent: true, completed: false)
        #expect(open == false)
        let nodes = visible(TranscriptTimeline.buildLive(live, agent: .claudeCode, replyOpen: open), store: store)
        #expect(hasLiveText(nodes), "the prose after the last call is the answer, which folding keeps")
        #expect(!nodes.contains { if case .activityTool = $0.content { return true }; return false },
                "the process rows fold away")
    }

    @Test func anUnfoldedLiveReplyKeepsItsProseOnTheRail() {
        let live = liveReplyWithAnswer()
        let store = ReplyFoldStore()
        store.beginRound()
        let nodes = visible(TranscriptTimeline.buildLive(live, agent: .claudeCode, replyOpen: true), store: store)
        let prose = nodes.first { if case .liveText = $0.content { return true }; return false }
        #expect(prose?.reply?.role == .body)
    }

    @Test func aTextOnlyLiveReplyCannotFold() {
        let live = LiveTurn()
        live.appendText("Just words")
        let nodes = TranscriptTimeline.buildLive(live, agent: .claudeCode, replyOpen: true)
        guard case .replyHeader(let header)? = nodes.first(where: { $0.reply?.role == .header })?.content else {
            Issue.record("a live reply keeps its Working header"); return
        }
        #expect(header.foldable == false)
        #expect(!nodes.contains { $0.reply?.role == .foot })
    }

    @Test func anAsyncDelegationStaysInViewWhileItsChildRuns() {
        let date = Date()
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "d1", name: "mcp__codeg-mcp__delegate_to_agent",
                         inputPreview: #"{"agent_type":"codex","task":"do it"}"#, status: .unknown, meta: nil),
                // The broker's acknowledgement: the CALL settled, the child runs.
                .toolResult(id: "d1", outputPreview: #"{"status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .text("Delegated; I'll report back."),
            ], timestamp: date),
        ]
        let store = ReplyFoldStore()   // fresh visit: settled replies open folded
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: store)
        guard let header = nodes.first(where: { $0.reply?.role == .header }) else {
            Issue.record("the reply has a header"); return
        }
        #expect(header.foldOpen == false)
        #expect(nodes.contains { $0.id == "tool-d1" }, "the running delegation is pinned while folded")
    }

    @Test func aDelegationStaysInViewWhenItsLatestCheckSaysStillRunning() {
        let date = Date()
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "d1", name: "delegate_to_agent",
                         inputPreview: #"{"agent_type":"codex","task":"do it"}"#, status: .unknown, meta: nil),
                .toolResult(id: "d1", outputPreview: #"{"status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                // The check RETURNED, reporting the task still running.
                .toolUse(id: "p1", name: "get_delegation_status",
                         inputPreview: #"{"task_id":"t1"}"#, status: .unknown, meta: nil),
                .toolResult(id: "p1", outputPreview: #"{"status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .text("Still working on it."),
            ], timestamp: date),
        ]
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: ReplyFoldStore())
        #expect(nodes.contains { $0.id == "tool-d1" })
    }

    @Test func aDelegationTheBrokerMarkedFinishedFoldsAway() {
        let date = Date()
        let meta = AnyJSON.parse(jsonString: #"{"codeg.delegation":{"status":"completed","task_id":"t1"}}"#)
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "d1", name: "delegate_to_agent",
                         inputPreview: #"{"agent_type":"codex","task":"do it"}"#, status: .unknown, meta: meta),
                .toolResult(id: "d1", outputPreview: #"{"status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .text("Delegated."),
            ], timestamp: date),
        ]
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: ReplyFoldStore())
        #expect(!nodes.contains { $0.id == "tool-d1" })
    }

    /// The web's background-task rows under `pinnedOnly`: the lane outlives a
    /// folded reply only for a task whose newest poll is still in flight.
    @Test func aFoldedReplyKeepsOnlyTheBackgroundTaskStillBeingPolledInView() {
        let live = LiveTurn()
        live.upsertToolCall(id: "p0", title: "TaskOutput", kind: "other", status: "completed",
                            rawInput: #"{"task_id":"b0","block":true,"timeout":60000}"#,
                            rawOutput: "<retrieval_status>success</retrieval_status>\n<task_id>b0</task_id>\n<status>completed</status>\n<exit_code>0</exit_code>\n<output>built</output>",
                            content: nil)
        live.upsertToolCall(id: "p1", title: "TaskOutput", kind: "other", status: "in_progress",
                            rawInput: #"{"task_id":"b1","block":true,"timeout":60000}"#, rawOutput: nil, content: nil)
        live.appendText("Waiting on the second build.")
        let store = ReplyFoldStore()
        store.beginRound()
        store.setOpen(false, key: live.id, isCurrent: true)

        let folded = visible(TranscriptTimeline.buildLive(live, agent: .claudeCode, replyOpen: false), store: store)
        #expect(folded.contains { $0.id == "bg:p0:b1" }, "the task still being polled stays in view")
        #expect(!folded.contains { $0.id == "bg:p0:b0" }, "the finished one folds away")

        store.setOpen(true, key: live.id, isCurrent: true)
        let open = visible(TranscriptTimeline.buildLive(live, agent: .claudeCode, replyOpen: true), store: store)
        let rows = open.filter { if case .backgroundTask = $0.content { return true }; return false }
        #expect(rows.map(\.id) == ["bg:p0:b0", "bg:p0:b1"])
    }

    // A refusal reports the task's real status — here "running" — but revived
    // nothing; and the check after it is still about the delegation before it,
    // which that check says has ended. Neither stays in view once folded.
    @Test func aRefusedResumeFoldsAwayAndLeavesTheDelegationItsCheck() {
        let date = Date()
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "d1", name: "mcp__codeg-mcp__delegate_to_agent",
                         inputPreview: #"{"agent_type":"codex","task":"Review"}"#, status: .unknown, meta: nil),
                .toolResult(id: "d1", outputPreview: #"{"status":"started","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .toolUse(id: "r1", name: "mcp__codeg-mcp__resume_delegation",
                         inputPreview: #"{"task_id":"t1"}"#, status: .unknown, meta: nil),
                .toolResult(id: "r1", outputPreview: #"{"agent_type":"codex","child_conversation_id":9,"error_code":"not_resumable","message":"Not resumed: the task is still running.","status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .toolUse(id: "p1", name: "mcp__codeg-mcp__get_delegation_status",
                         inputPreview: #"{"task_ids":["t1"]}"#, status: .unknown, meta: nil),
                .toolResult(id: "p1", outputPreview: #"{"status":"completed","task_id":"t1","text":"Reviewed."}"#,
                            isError: false, agentStats: nil),
                .text("Reviewed."),
            ], timestamp: date),
        ]
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: ReplyFoldStore())
        #expect(!nodes.contains { $0.id == "tool-r1" }, "a refused resume is no running sub-agent")
        #expect(!nodes.contains { $0.id == "tool-d1" }, "the delegation's own check says it ended")
    }

    @Test func aRefusedResumeOfARunningTaskIsNoRunningSubAgent() {
        let date = Date()
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "r1", name: "mcp__codeg-mcp__resume_delegation",
                         inputPreview: #"{"task_id":"t1"}"#, status: .unknown, meta: nil),
                // The task's REAL status, which a resume that happened would
                // report too: only the code says this one did not.
                .toolResult(id: "r1", outputPreview: #"{"agent_type":"codex","child_conversation_id":9,"error_code":"not_resumable","message":"Not resumed: the task is still running.","status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .text("It is still running; I'll check on it."),
            ], timestamp: date),
        ]
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: ReplyFoldStore())
        #expect(!nodes.contains { $0.id == "tool-r1" })
    }

    @Test func aRunningCodeModeDelegationIsADelegationCardKeptInView() {
        let date = Date()
        let code = #"await tools[\"codeg-mcp\"].delegate_to_agent({ agent_type: \"codex\", task: `do it` })"#
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "c1", name: "execute", inputPreview: #"{"code":""# + code + #""}"#,
                         status: .unknown, meta: nil),
                .toolResult(id: "c1", outputPreview: #"{"status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .text("Delegated."),
            ], timestamp: date),
        ]
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: ReplyFoldStore())
        guard let node = nodes.first(where: { $0.id == "tool-c1" }) else {
            Issue.record("the running delegation is pinned while folded"); return
        }
        guard case .delegation(let vm, _) = node.content else {
            Issue.record("a delegation draws as its card, not an activity row"); return
        }
        #expect(vm.companion == .delegate)
    }

    @Test func aFinishedDelegationLeavesAFoldedReplyOnItsBindingsWord() {
        let date = Date()
        let turns = [
            MessageTurn(id: "u", role: .user, blocks: [.text("go")], timestamp: date),
            MessageTurn(id: "a", role: .assistant, blocks: [
                .toolUse(id: "d1", name: "mcp__codeg-mcp__delegate_to_agent",
                         inputPreview: #"{"agent_type":"codex","task":"audit"}"#, status: .unknown, meta: nil),
                .toolResult(id: "d1", outputPreview: #"{"status":"running","task_id":"t1"}"#,
                            isError: false, agentStats: nil),
                .text("Delegated."),
            ], timestamp: date),
        ]
        let built = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .claudeCode,
                                                      suppressInFlight: false)
        func binding(_ status: DelegationBinding.Status) -> ActivityLive {
            var live = ActivityLive.none
            live.delegations = [DelegationBinding(
                info: DelegationInfo(parentToolUseId: "d1", childConnectionId: "c", childConversationId: 5,
                                     agentType: .codex, taskPreview: nil, taskId: "t1", assistantId: nil,
                                     assistantName: nil),
                status: status, errorCode: nil)]
            return live
        }
        // The ack alone says running: pinned while folded.
        #expect(ReplyFolding.apply(built, store: ReplyFoldStore()).contains { $0.id == "tool-d1" })
        #expect(ReplyFolding.apply(built, store: ReplyFoldStore(), live: binding(.running)).contains { $0.id == "tool-d1" })
        // The binding saw it finish: folded away with the rest of the steps.
        #expect(!ReplyFolding.apply(built, store: ReplyFoldStore(), live: binding(.ok)).contains { $0.id == "tool-d1" })
    }

    @Test func theNewestReplyIsCurrentEvenWithoutAHeader() {
        let date = Date()
        let turns = [
            MessageTurn(id: "u1", role: .user, blocks: [.text("one")], timestamp: date),
            MessageTurn(id: "a1", role: .assistant, blocks: [
                .toolUse(id: "r1", name: "Read", inputPreview: #"{"file_path":"/r/a.ts"}"#, status: .unknown, meta: nil),
                .toolResult(id: "r1", outputPreview: "x", isError: false, agentStats: nil),
                .text("done"),
            ], timestamp: date, durationMs: 1000),
            MessageTurn(id: "u2", role: .user, blocks: [.text("two")], timestamp: date),
            // No steps and no duration: no header of its own.
            MessageTurn(id: "a2", role: .assistant, blocks: [.text("plain")], timestamp: date),
        ]
        let store = ReplyFoldStore()
        store.arm()
        let nodes = visible(TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false), store: store)
        let first = nodes.first { $0.reply?.role == .header && $0.reply?.key == "a1" }
        #expect(first?.currentRound == false, "the older reply must not inherit the current round")
        #expect(first?.foldOpen == false)
    }
}
