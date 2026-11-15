import Foundation
import Testing
@testable import Codeg

/// A live reply the agent began on its own — nothing between it and the
/// reply above — is that reply's continuation (Android 0cf00e4, web
/// `mergeConsecutiveAssistantTurns` with the live turn included).
@MainActor
struct LiveJoinTests {
    private let date = Date(timeIntervalSince1970: 1_792_000_000)
    private let agent = AgentType.claudeCode

    private func user(_ id: String, _ text: String) -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text(text)], timestamp: date)
    }

    /// A settled reply that read a file, then answered.
    private func reply(_ id: String, answer: String) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: [
            .toolUse(id: "\(id)-read", name: "Read", inputPreview: #"{"file_path":"/a.swift"}"#,
                     status: .unknown, meta: nil),
            .toolResult(id: "\(id)-read", outputPreview: "let a = 1", isError: false, agentStats: nil),
            .text(answer),
        ], timestamp: date, durationMs: 4_000)
    }

    private func tier(_ turns: [MessageTurn], pending: [MessageTurn] = []) -> TranscriptTimeline.PersistedTier {
        TranscriptTimeline.buildPersistedTier(turns: turns, pending: pending, agent: agent, suppressInFlight: false)
    }

    private func headers(_ nodes: [TimelineNode]) -> [TimelineNode.ReplyHeader] {
        nodes.compactMap { node in
            if case .replyHeader(let header) = node.content { return header }
            return nil
        }
    }

    private func role(ofText text: String, in nodes: [TimelineNode]) -> TimelineNode.ReplyMembership.Role? {
        nodes.first { node in
            switch node.content {
            case .assistantText(let s): return s == text
            case .liveText(let run, _): return run.text == text
            default: return false
            }
        }?.reply?.role
    }

    @Test func theTierRemembersTheReplyItEndsWith() {
        let ends = tier([user("u", "go"), reply("a", answer: "Done.")])
        #expect(ends.tail?.ownerID == "a")
        #expect(ends.tail.map { ends.nodes[$0.nodeStart].id } == "a#header")
        // A prompt after it — persisted or optimistic — stands between.
        #expect(tier([user("u", "go"), reply("a", answer: "Done."), user("u2", "more")]).tail == nil)
        #expect(tier([user("u", "go"), reply("a", answer: "Done.")], pending: [user("p", "more")]).tail == nil)
    }

    @Test func aReplyTheAgentBeganOnItsOwnJoinsTheOneAbove() {
        let persisted = tier([user("u", "go"), reply("a", answer: "Done.")])
        let live = LiveTurn(id: "live-1")
        live.upsertToolCall(id: "tc-1", title: "Read /b.swift", kind: "read", status: "completed",
                            rawInput: #"{"file_path":"/b.swift"}"#, rawOutput: "let b = 2", content: nil)
        live.appendText("And b is 2.")
        live.flushAllText()
        // Folded: the answer is split off (open, a reply still being written
        // keeps its closing words on the rail).
        let nodes = TranscriptTimeline.appendingLive(live, to: persisted, agent: agent) { _ in false }

        let all = headers(nodes)
        #expect(all.count == 1, "one reply, one header")
        #expect(all.first?.replyKey == "a", "under the earlier reply's id, which its persisted merge keeps")
        #expect(all.first?.summary.steps == 2, "both replies' steps counted")
        #expect(all.first?.completed == false)
        #expect(!nodes.contains { $0.id == "a#footer" }, "the earlier footer gives way to the live turn's end")
        #expect(nodes.allSatisfy { $0.reply == nil || $0.reply?.key == "a" })
        // The live reply took a step: the earlier answer is now process,
        // the new words the answer.
        #expect(role(ofText: "Done.", in: nodes) == .body)
        #expect(role(ofText: "And b is 2.", in: nodes) == .always)
    }

    @Test func wordsAloneJoinTheEarlierAnswer() {
        let persisted = tier([user("u", "go"), reply("a", answer: "Done.")])
        let live = LiveTurn(id: "live-2")
        live.appendText("One more thing.")
        live.flushAllText()
        live.isStreaming = false
        let nodes = TranscriptTimeline.appendingLive(live, to: persisted, agent: agent) { _ in false }
        #expect(headers(nodes).count == 1)
        #expect(role(ofText: "Done.", in: nodes) == .always)
        #expect(role(ofText: "One more thing.", in: nodes) == .always)
    }

    @Test func aPromptBetweenKeepsThemApart() {
        let persisted = tier([user("u", "go"), reply("a", answer: "Done.")], pending: [user("p", "more")])
        let live = LiveTurn(id: "live-3")
        live.upsertToolCall(id: "tc-1", title: "Read /b.swift", kind: "read", status: "completed",
                            rawInput: #"{"file_path":"/b.swift"}"#, rawOutput: "let b = 2", content: nil)
        let nodes = TranscriptTimeline.appendingLive(live, to: persisted, agent: agent) { _ in true }
        #expect(headers(nodes).map(\.replyKey) == ["a", "live-3"])
        #expect(nodes.contains { $0.id == "a#footer" })
    }

    @Test func onlyTheStretchBeforeASteerJoins() {
        let persisted = tier([user("u", "go"), reply("a", answer: "Done.")])
        let live = LiveTurn(id: "live-4")
        live.upsertToolCall(id: "tc-1", title: "Read /b.swift", kind: "read", status: "completed",
                            rawInput: #"{"file_path":"/b.swift"}"#, rawOutput: "let b = 2", content: nil)
        live.insertSteering(SteeredMessage(id: "m1", text: "also c", at: date))
        live.upsertToolCall(id: "tc-2", title: "Read /c.swift", kind: "read", status: "in_progress",
                            rawInput: #"{"file_path":"/c.swift"}"#, rawOutput: "", content: nil)
        let nodes = TranscriptTimeline.appendingLive(live, to: persisted, agent: agent) { _ in true }
        #expect(headers(nodes).map(\.replyKey) == ["a", "live-4~m1"])
        #expect(headers(nodes).first?.summary.steps == 2)
        #expect(headers(nodes).first?.completed == true, "the steer closed the joined reply")
    }

    @Test func nothingSaidYetWorksUnderTheReplyItJoins() {
        let persisted = tier([user("u", "go"), reply("a", answer: "Done.")])
        let live = LiveTurn(id: "live-5")
        let nodes = TranscriptTimeline.appendingLive(live, to: persisted, agent: agent) { _ in true }
        #expect(headers(nodes).map(\.replyKey) == ["a"])
        let thinking = nodes.firstIndex { if case .thinking = $0.content { return true }; return false }
        let header = nodes.firstIndex { $0.id == "a#header" }
        #expect(thinking != nil && header != nil && thinking! > header!, "below the reply, not above its header")
        #expect(nodes.first?.id == "u")
    }
}
