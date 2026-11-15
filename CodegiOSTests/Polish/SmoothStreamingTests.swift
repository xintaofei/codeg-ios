import Foundation
import Testing
@testable import Codeg

/// What keeps a reply being written from blinking: rows that keep their
/// identity as they change shape, the working dots where the first words
/// will land, and the reader's own toggles told apart from the stream's
/// growth.
@MainActor
struct SmoothStreamingTests {
    private let agent = AgentType.claudeCode

    private func read(_ live: LiveTurn, _ id: String, _ path: String, status: String = "completed") {
        live.upsertToolCall(id: id, title: "Read \(path)", kind: "read", status: status,
                            rawInput: #"{"file_path":"\#(path)"}"#,
                            rawOutput: status == "completed" ? "let x = 1" : "", content: nil)
    }

    @Test func aCallTheNextOneJoinsStaysTheSameRowAsItBecomesTheirGroup() {
        let live = LiveTurn(id: "live-1")
        read(live, "r1", "/a.swift")
        let alone = TranscriptTimeline.buildLive(live, agent: agent)
        #expect(alone.filter { $0.id == "tool-r1" }.count == 1)

        read(live, "r2", "/b.swift", status: "in_progress")
        let joined = TranscriptTimeline.buildLive(live, agent: agent)
        let row = joined.filter { $0.id == "tool-r1" }
        #expect(row.count == 1, "the first call's row is the group's")
        if case .activityGroup(_, let steps, _, _)? = row.first?.content {
            #expect(steps.map(\.call.id) == ["r1", "r2"])
        } else {
            Issue.record("expected the group under the first call's id")
        }
        #expect(!joined.contains { $0.id == "tool-r2" }, "the joining call has no row of its own")
        #expect(!joined.contains { $0.id.hasPrefix("toolgroup-") })
    }

    @Test func theWorkingDotsSitUnderTheHeaderTheFirstWordsWillTakeTheirPlace() {
        let live = LiveTurn(id: "live-2")
        let waiting = TranscriptTimeline.buildLive(live, agent: agent)
        let header = waiting.firstIndex { $0.id == "live-2#header" }
        let dots = waiting.firstIndex { if case .thinking = $0.content { return true }; return false }
        #expect(header != nil && dots != nil && dots! > header!, "the header stays put; the dots go below it")

        live.appendText("On it.")
        live.flushAllText()
        let speaking = TranscriptTimeline.buildLive(live, agent: agent)
        #expect(speaking.firstIndex { $0.id == "live-2#header" } == header, "the header doesn't move")
        #expect(!speaking.contains { if case .thinking = $0.content { return true }; return false })
    }

    @Test func theReadersOwnTogglesAreTimed() {
        let disclosures = DisclosureStore()
        #expect(disclosures.lastChoiceAt == 0)
        disclosures.set(true, for: "tool-1/tool")
        #expect(disclosures.lastChoiceAt > 0)

        let folds = ReplyFoldStore()
        #expect(folds.lastChoiceAt == 0)
        folds.setOpen(false, key: "a", isCurrent: false)
        #expect(folds.lastChoiceAt > 0)
    }
}

/// When the transcript follows the end, and when it lets go.
struct BottomFollowTests {
    private let slack: CGFloat = 80

    /// A list 600 tall over `content`, scrolled to `offset`.
    private func edge(_ offset: CGFloat, content: CGFloat, visible: CGFloat = 600) -> BottomEdge {
        BottomEdge(offset: offset, visibleBottom: visible, contentHeight: content)
    }

    private func act(_ old: BottomEdge, _ new: BottomEdge, following: Bool = true,
                     reader: Bool = false, toggled: Bool = false) -> BottomFollow.Action {
        BottomFollow.action(old: old, new: new, following: following, readerScrolling: reader,
                            readerJustToggled: toggled, threshold: slack)
    }

    @Test func growthUnderAReaderAtTheEndIsFollowedHoweverTall() {
        #expect(act(edge(400, content: 1000), edge(400, content: 1020)) == .glide, "a streamed line")
        #expect(act(edge(400, content: 1000), edge(400, content: 1300)) == .glide,
                "a step taller than the slack no longer unpins")
        #expect(act(edge(400, content: 1000), edge(400, content: 1300), following: false) == .follow(false),
                "a reader up in the history stays put")
    }

    @Test func aReaderTakingHoldMidGlideLetsGoWithoutACrossing() {
        // 300 grew, the glide has covered 50: 250 below, then the reader drags up.
        let mid = edge(450, content: 1300)
        #expect(act(mid, edge(440, content: 1300), reader: true) == .follow(false),
                "no crossing of the slack, and still the follow lets go")
        #expect(act(edge(440, content: 1300), edge(430, content: 1320), following: false, reader: true) == .none)
        // Back down to the end by hand: following again.
        #expect(act(edge(600, content: 1300), edge(660, content: 1300), following: false, reader: true) == .follow(true))
    }

    @Test func theProgramsOwnScrollsChangeOnlyOnACrossing() {
        // A glide's frames on the way down.
        #expect(act(edge(450, content: 1300), edge(500, content: 1300)) == .none)
        #expect(act(edge(600, content: 1300), edge(650, content: 1300), following: false) == .follow(true))
        // A jump to a message far above.
        #expect(act(edge(700, content: 1300), edge(100, content: 1300), following: false) == .follow(false))
    }

    @Test func theKeyboardPinsAtOnceAndARowTheReaderOpenedGrowsInPlace() {
        #expect(act(edge(700, content: 1300), edge(700, content: 1300, visible: 300)) == .pin)
        #expect(act(edge(700, content: 1300), edge(700, content: 1420), toggled: true) == .follow(false),
                "opened by hand: the list stays where they tapped it")
        #expect(act(edge(700, content: 1300), edge(700, content: 1340), toggled: true) == .none)
    }
}
