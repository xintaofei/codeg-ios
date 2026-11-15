import Foundation
import Testing
@testable import Codeg

/// A delegation read across the thread: the newest check on its task, made
/// replies later (Android `DelegationTaskIndex`); the reply header counting
/// it as its card stands; and a running child's live progress (web
/// `progressFromLiveContent`).
@MainActor
struct DelegationThreadTests {
    private let date = Date(timeIntervalSince1970: 1_792_000_000)

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func turn(_ id: String, _ role: TurnRole, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: id, role: role, blocks: blocks, timestamp: date)
    }

    /// Reply 1 hands t-1 over; reply 2 checks it (`ending` as the report says).
    private func thread(ending: String) -> [MessageTurn] {
        [
            turn("u1", .user, [.text("Hand it over")]),
            turn("a1", .assistant, [
                .toolUse(id: "d1", name: "mcp__codeg-mcp__delegate_to_agent",
                         inputPreview: json(["agent_type": "codex", "task": "Write the changelog"]), status: .unknown, meta: nil),
                .toolResult(id: "d1", outputPreview: json(["task_id": "t-1", "status": "running", "agent_type": "codex"]),
                            isError: false, agentStats: nil),
                .text("Codex is on it."),
            ]),
            turn("u2", .user, [.text("Done yet?")]),
            turn("a2", .assistant, [
                .toolUse(id: "q1", name: "mcp__codeg-mcp__get_delegation_status",
                         inputPreview: json(["task_ids": ["t-1"]]), status: .unknown, meta: nil),
                .toolResult(id: "q1", outputPreview: json(["tasks": [["task_id": "t-1", "status": ending,
                                                                       "message": "Changelog written."]]]),
                            isError: false, agentStats: nil),
                .text("Checked."),
            ]),
        ]
    }

    private func tier(_ turns: [MessageTurn]) -> TranscriptTimeline.PersistedTier {
        TranscriptTimeline.buildPersistedTier(turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false)
    }

    private func delegateVM(in tier: TranscriptTimeline.PersistedTier) -> (ToolCallVM, DelegationTaskRow?)? {
        for node in tier.nodes {
            if case .delegation(let vm, let later) = node.content { return (vm, later) }
        }
        return nil
    }

    @Test func aCheckRepliesLaterSaysHowTheDelegationStands() throws {
        let built = tier(thread(ending: "completed"))
        let (vm, later) = try #require(delegateVM(in: built))
        #expect(later == nil, "its own reply holds no check")
        #expect(ActivityLive.none.delegationCard(vm, later: later)?.status == .running, "the ack alone: running")
        var live = ActivityLive.none
        live.delegationTasks = built.delegationFold.index(version: 1)
        #expect(live.delegationTasks.row(for: "d1")?.taskId == "t-1")
        #expect(live.delegationCard(vm, later: later)?.status == .ok, "the later check says it is done")
    }

    @Test func aResumeTakesOverTheChecksAfterIt() {
        var turns = thread(ending: "running")
        turns.insert(turn("a1b", .assistant, [
            .toolUse(id: "r1", name: "mcp__codeg-mcp__resume_delegation",
                     inputPreview: json(["task_id": "t-1", "reason": "restart"]), status: .unknown, meta: nil),
            .toolResult(id: "r1", outputPreview: json(["task_id": "t-1", "status": "running",
                                                       "message": "Delegation resumed. task_id=t-1"]),
                        isError: false, agentStats: nil),
        ]), at: 2)
        let index = tier(turns).delegationFold.index(version: 1)
        #expect(index.row(for: "r1") != nil, "the resume owns the check after it")
        #expect(index.row(for: "d1") == nil)
    }

    @Test func theIndexIsEqualByItsBuild() {
        let fold = tier(thread(ending: "completed")).delegationFold
        #expect(fold.index(version: 3) == fold.index(version: 3))
        #expect(fold.index(version: 3) != fold.index(version: 4))
    }

    @Test func theHeaderCountsADelegationThatFailedAfterItsReply() throws {
        let built = tier(Array(thread(ending: "running").prefix(2)))
        let header = try #require(built.nodes.compactMap { node -> TimelineNode.ReplyHeader? in
            if case .replyHeader(let h) = node.content { return h }
            return nil
        }.first)
        #expect(header.hasDelegations)
        #expect(ActivityLive.none.summary(of: header).unrecovered == 0)
        var live = ActivityLive.none
        live.delegations = [DelegationBinding(
            info: DelegationInfo(parentToolUseId: "d1", childConnectionId: "child", childConversationId: 9,
                                 agentType: .codex, taskPreview: nil, taskId: "t-1", assistantId: nil, assistantName: nil),
            status: .err, errorCode: "agent_crashed")]
        let summary = live.summary(of: header)
        #expect(summary.failed == 1)
        #expect(summary.unrecovered == 1)
        #expect(summary.steps == header.summary.steps, "a step either way")
    }

    // MARK: Child progress

    @Test func theChildsCallsSayHowFarItGot() {
        var tally = ChildStepTally()
        #expect(tally.progress == nil, "no call yet, no bar")
        tally.apply(.toolCall(id: "c1", title: "npm audit --json", kind: "execute", status: "completed",
                              content: nil, rawInput: nil, rawOutput: nil, meta: nil))
        tally.apply(.toolCall(id: "c2", title: "Read package.json\nmore", kind: "read", status: "in_progress",
                              content: nil, rawInput: nil, rawOutput: nil, meta: nil))
        #expect(tally.progress == DelegationProgress(steps: 1, lastStep: "Read package.json"))
        let moved = tally.apply(.toolCallUpdate(id: "c2", title: nil, status: "failed", content: nil, rawInput: nil,
                                                rawOutput: nil, append: false, meta: nil))
        #expect(moved)
        #expect(tally.progress?.steps == 2, "a failed call is a finished step")
        let unknown = tally.apply(.toolCallUpdate(id: "zz", title: "x", status: "completed", content: nil, rawInput: nil,
                                                  rawOutput: nil, append: false, meta: nil))
        #expect(!unknown, "an unknown call moves nothing")
        let restarted = tally.apply(.userMessage(messageId: "m", blocks: []))
        #expect(restarted, "a new prompt starts over")
        #expect(tally.progress == nil)
    }

    @Test func aRunningClockReadsAsAClock() {
        #expect(LiveClockStore.clock(21) == "0:21")
        #expect(LiveClockStore.clock(724) == "12:04")
        #expect(LiveClockStore.clock(3729) == "1:02:09")
        let clocks = LiveClockStore()
        let first = clocks.start(for: "call", now: date)
        #expect(clocks.start(for: "call", now: date.addingTimeInterval(30)) == first, "counted from when first seen")
    }
}
