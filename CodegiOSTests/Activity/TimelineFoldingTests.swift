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
