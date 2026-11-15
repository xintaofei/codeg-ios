import Foundation
import Testing
@testable import Codeg

/// Where a compaction goes on the timeline, and how often — Android's
/// `TranscriptTimelineTest` cases from 52f2021 (web `hoistedCompaction`,
/// `dedupeCompactionItems`, `isEmptyTurnItem`).
@MainActor
struct TimelineCompactionTests {
    private let agent: AgentType = .codex
    private static let date = Date(timeIntervalSince1970: 0)

    private func user(_ id: String, _ text: String) -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text(text)], timestamp: Self.date)
    }

    private func assistant(_ id: String, _ text: String) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: [.text(text)], timestamp: Self.date)
    }

    private static func compactionMeta(_ extra: String = "") -> AnyJSON? {
        AnyJSON.parse(jsonString: #"{"contextCompaction":{"version":1"# + extra + "}}")
    }

    /// A compaction-only turn, as the history parsers write one.
    private func compaction(_ id: String, callID: String? = nil, extra: String = "") -> MessageTurn {
        let call = callID ?? "\(id)-call"
        return MessageTurn(id: id, role: .assistant, blocks: [
            .toolUse(id: call, name: "Context compacted", inputPreview: nil, status: .unknown,
                     meta: Self.compactionMeta(extra)),
            .toolResult(id: call, outputPreview: "", isError: false, agentStats: nil),
        ], timestamp: Self.date)
    }

    /// The persisted and live tiers joined as the transcript joins them.
    private func build(_ turns: [MessageTurn], live: LiveTurn? = nil) -> [TimelineNode] {
        var all = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: agent,
                                                    suppressInFlight: false)
        if let live { all += TranscriptTimeline.buildLive(live, agent: agent) }
        return TranscriptTimeline.dedupeCompactions(all)
    }

    /// Prompts, reply headers and footers, and compactions — a divider
    /// between turns, or a step of the reply it is in.
    private func shape(_ nodes: [TimelineNode]) -> [String] {
        nodes.compactMap { node in
            switch node.content {
            case .user: return "user:\(node.id)"
            case .replyHeader(let header): return "header:\(header.replyKey)"
            case .footer: return "footer:\(node.id)"
            case .compaction:
                if let reply = node.reply { return "step:\(reply.key)" }
                return "divider:\(node.id)"
            default: return nil
            }
        }
    }

    private func compactions(_ nodes: [TimelineNode]) -> [TimelineNode] {
        nodes.filter { if case .compaction = $0.content { return true }; return false }
    }

    // MARK: - Between turns, or in the reply

    @Test func aCompactionBetweenRepliesDividesThem() {
        let nodes = build([user("u1", "q"), assistant("a1", "done"), compaction("c1"), user("u2", "next")])
        #expect(shape(nodes) == ["user:u1", "footer:a1#footer", "divider:c1#0", "user:u2"])
        // The reply before it keeps its answer: the compaction no longer
        // stands at its end in the answer's place.
        #expect(nodes.first { $0.id == "a1#0" }?.reply?.role == .always)
        // A divider is in no reply, so folding never hides it.
        #expect(ReplyFolding.apply(nodes, store: ReplyFoldStore()).contains { $0.id == "c1#0" })
    }

    @Test func aCompactionTheAgentRanMidReplyStaysAStep() {
        // The agent compacted by itself and went on with the same reply.
        let nodes = build([user("u1", "q"), assistant("a1", "working"), compaction("c1"), assistant("a2", "done")])
        #expect(shape(nodes) == ["user:u1", "header:a1", "step:a1", "footer:a1#footer"])
    }

    @Test func aCompactionAtTheEndIsADivider() {
        #expect(shape(build([user("u1", "/compact"), compaction("c1")])) == ["user:u1", "divider:c1#0"])
        // Past other compactions, nothing of the agent's follows either.
        #expect(shape(build([user("u1", "q"), assistant("a1", "x"), compaction("c1"), compaction("c2")]))
                == ["user:u1", "footer:a1#footer", "divider:c1#0", "divider:c2#0"])
    }

    @Test func aCompactionMidReplyIsSeenPastAnEmptyPlaceholder() {
        let empty = MessageTurn(id: "s1", role: .system, blocks: [], timestamp: Self.date)
        let nodes = build([user("u1", "q"), assistant("a1", "working"), compaction("c1"), empty,
                           assistant("a2", "done")])
        #expect(shape(nodes) == ["user:u1", "header:a1", "step:a1", "footer:a1#footer"])
    }

    @Test func aRunningCompactionInTheRunningRoundSaysSo() {
        let open = MessageTurn(id: "c1", role: .assistant, blocks: [
            .toolUse(id: "c1-call", name: "Context compacting", inputPreview: nil, status: .unknown,
                     meta: Self.compactionMeta()),
        ], timestamp: Self.date)
        let nodes = TranscriptTimeline.buildPersisted(
            turns: [user("u1", "/compact"), open], pending: [], agent: agent,
            suppressInFlight: false, inFlightUserTurnId: "u1")
        guard case .compaction(let info)? = compactions(nodes).first?.content else {
            Issue.record("expected a divider"); return
        }
        #expect(info.running)
    }

    // MARK: - Drawn once

    @Test func oneCompactionReachingTheThreadTwiceIsDrawnOnceByItsCallID() {
        // codex: the live call and the transcript's divider share the call id.
        let live = LiveTurn()
        live.upsertToolCall(id: "c1-call", title: "Context compacted", kind: "", status: "completed",
                            rawInput: nil, rawOutput: "", content: nil, meta: Self.compactionMeta())
        let nodes = build([user("u1", "/compact"), compaction("c1")], live: live)
        #expect(compactions(nodes).map(\.id) == ["c1#0"], "the first copy is kept")
    }

    @Test func oneCompactionReachingTheThreadTwiceIsDrawnOnceByItsFigures() {
        // claude: under different ids, the figures name the event.
        let figures = #","preTokens":9,"postTokens":4,"durationMs":70"#
        let live = LiveTurn()
        live.upsertToolCall(id: "compacting-status", title: "Compacting", kind: "", status: "completed",
                            rawInput: nil, rawOutput: "", content: nil, meta: Self.compactionMeta(figures))
        let nodes = build([user("u1", "/compact"), compaction("c1", extra: figures)], live: live)
        #expect(compactions(nodes).count == 1)
    }

    @Test func separateBareCompactionsStaySeparate() {
        // codex's bare markers under different ids are two compactions.
        let nodes = build([user("u1", "q"), compaction("c1"), user("u2", "q"), compaction("c2")])
        #expect(compactions(nodes).count == 2)
    }

    @Test func aRepeatsOtherIdentityNamesTheSameEventToo() {
        // The second copy matches the first by its figures and brings a new
        // call id; a third under that id is the same event again.
        let nodes = TranscriptTimeline.dedupeCompactions([
            TranscriptTimeline.compactionNode(
                CompactionInfo(before: 9, after: 4, running: false, callID: "a", eventKey: "compaction:9:4:70"),
                id: "one", agent: agent),
            TranscriptTimeline.compactionNode(
                CompactionInfo(before: 9, after: 4, running: false, callID: "b", eventKey: "compaction:9:4:70"),
                id: "two", agent: agent),
            TranscriptTimeline.compactionNode(
                CompactionInfo(before: nil, after: nil, running: false, callID: "b"),
                id: "three", agent: agent),
        ])
        #expect(nodes.map(\.id) == ["one"])
    }

    // MARK: - Empty placeholders

    @Test func anEmptyPlaceholderTurnDoesNotCutAReplyInTwo() {
        let nodes = build([
            user("u1", "q"),
            assistant("a1", "first"),
            MessageTurn(id: "s1", role: .system, blocks: [], timestamp: Self.date),
            MessageTurn(id: "p1", role: .user, blocks: [.text(" ")], timestamp: Self.date),
            assistant("a2", "second"),
        ])
        #expect(shape(nodes) == ["user:u1", "footer:a1#footer"])
        #expect(nodes.contains { $0.id == "a1#1" }, "the second half is the same reply's")
    }

    @Test func aFailedRoundsClosingLineStillEndsTheReply() {
        let nodes = build([
            user("u1", "q"),
            assistant("a1", "first"),
            MessageTurn(id: "e1", role: .system, blocks: [.turnError("stream disconnected")], timestamp: Self.date),
            assistant("a2", "second"),
        ])
        #expect(shape(nodes) == ["user:u1", "footer:a1#footer", "footer:a2#footer"])
        #expect(nodes.contains { if case .error = $0.content { return $0.id == "e1" }; return false })
    }

    // MARK: - Live

    @Test func aLiveCompactionIsADividerUntilTheReplyGoesOn() {
        let live = LiveTurn()
        live.upsertToolCall(id: "k1", title: "Compacting", kind: "", status: "in_progress",
                            rawInput: nil, rawOutput: nil, content: nil, meta: Self.compactionMeta())
        let alone = TranscriptTimeline.buildLive(live, agent: agent)
        #expect(shape(alone) == ["divider:\(live.id)#0"])
        #expect(!alone.contains { if case .thinking = $0.content { return true }; return false })

        live.appendText("carrying on")
        #expect(shape(TranscriptTimeline.buildLive(live, agent: agent)) == ["header:\(live.id)", "step:\(live.id)"])
    }
}
