import Foundation
import Testing
@testable import Codeg

/// A transcript read replaces the reply that streamed only once it holds that
/// reply's closing words. The server ends the turn a beat before the agent's
/// last write lands, and a read in that gap stops at the reply's last tool call.
@MainActor
struct ReplyReconcileTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func user(_ text: String, id: String = UUID().uuidString) -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text(text)], timestamp: at)
    }

    private func assistant(_ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: UUID().uuidString, role: .assistant, blocks: blocks, timestamp: at)
    }

    private var toolCall: [ContentBlock] {
        [.toolUse(id: "t1", name: "Bash", inputPreview: #"{"command":"swift test"}"#, status: .unknown, meta: nil),
         .toolResult(id: "t1", outputPreview: "ok", isError: false, agentStats: nil)]
    }

    private let answer = "All 42 tests pass now. The fix was in the parser's window offset."

    /// The round before this one, then this round's prompt at index 2.
    private var earlier: [MessageTurn] {
        [user("Hi"), assistant([.text("Hello! What should I look at?")])]
    }

    @Test func aReadThatStopsAtTheLastToolCallDoesNotHoldTheReply() {
        let read = earlier + [user("Run the tests"), assistant([.text("Let me run them.")] + toolCall)]
        #expect(!ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                           evidence: ReplyReconcile.evidence(of: answer)))
    }

    @Test func theSameReadOnceTheAnswerLandsDoes() {
        let read = earlier + [user("Run the tests"), assistant([.text("Let me run them.")] + toolCall),
                              assistant([.text(answer)])]
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                          evidence: ReplyReconcile.evidence(of: answer)))
    }

    @Test func theAnswerMayBeSplitAndSpacedDifferently() {
        // Two blocks, a line break where a space streamed, none between them.
        let read = earlier + [user("Run the tests"),
                              assistant([.text("All 42 tests pass\nnow."), .text(" The fix was in the parser's window offset.\n")])]
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                          evidence: ReplyReconcile.evidence(of: answer)))
    }

    @Test func anEarlierRoundSayingTheSameDoesNotCount() {
        let read = [user("Run the tests"), assistant([.text(answer)]),
                    user("Run them again"), assistant([.text("Running.")] + toolCall)]
        #expect(!ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                           evidence: ReplyReconcile.evidence(of: answer)))
    }

    @Test func thePromptSayingItDoesNotCount() {
        let read = earlier + [user("Reply with exactly: \(answer)"), assistant(toolCall)]
        #expect(!ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                           evidence: ReplyReconcile.evidence(of: answer)))
    }

    @Test func aReplyThatStreamedOnlyPartlyIsHeldByTheWholeOne() {
        // The connection dropped mid-answer; the transcript has all of it.
        let partial = "All 42 tests pass now. The fix was in the par"
        let read = earlier + [user("Run the tests"), assistant(toolCall), assistant([.text(answer)])]
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                          evidence: ReplyReconcile.evidence(of: partial)))
    }

    @Test func onlyTheClosingWordsAreAskedFor() {
        // The record lacks the stream's opening line; its closing words agree.
        let body = "Everything compiles, and the suite is green: " + answer
        let evidence = ReplyReconcile.evidence(of: "An intro the record leaves out. " + body)
        #expect(evidence?.count == ReplyReconcile.evidenceLength)
        let read = earlier + [user("Run the tests"), assistant([.text(body)])]
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false, evidence: evidence))
    }

    @Test func withoutProseTheShapeDecides() {
        let read = earlier + [user("Run the tests"), assistant(toolCall)]
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false, evidence: nil))
        #expect(ReplyReconcile.evidence(of: nil) == nil)
        #expect(ReplyReconcile.evidence(of: " … 👍 \n") == nil)
    }

    @Test func aReadEndingOnThePromptOrNothingHoldsNoReply() {
        #expect(!ReplyReconcile.holdsReply(earlier + [user("Run the tests")], roundStart: 2,
                                           localRoundFailed: false, evidence: nil))
        #expect(!ReplyReconcile.holdsReply([], roundStart: 0, localRoundFailed: false, evidence: nil))
        #expect(!ReplyReconcile.holdsReply(earlier + [user("Go"), assistant([.text("  ")])], roundStart: 2,
                                           localRoundFailed: false, evidence: nil))
    }

    @Test func aFailureLineCountsOnlyWhenThisRoundFailed() {
        let failure = MessageTurn(id: "f", role: .system, blocks: [.turnError("rate limited")], timestamp: at)
        let read = earlier + [user("Run the tests"), failure]
        let evidence = ReplyReconcile.evidence(of: "Running")
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: true, evidence: evidence))
        #expect(!ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false, evidence: evidence))
    }

    @Test func aRoundStartOutsideTheReadIsClamped() {
        let read = [user("Run the tests"), assistant([.text(answer)])]
        let evidence = ReplyReconcile.evidence(of: answer)
        // The window opened past where the round began: all of it is the round.
        #expect(ReplyReconcile.holdsReply(read, roundStart: -3, localRoundFailed: false, evidence: evidence))
        // Past the end: nothing of the round is in the read.
        #expect(!ReplyReconcile.holdsReply(read, roundStart: 9, localRoundFailed: false, evidence: evidence))
    }

    @Test func chineseProseCountsAsWords() {
        let closing = "测试已全部通过，问题出在解析器的窗口偏移上。"
        let read = earlier + [user("跑一下测试"), assistant([.text("测试已全部通过，\n问题出在解析器的窗口偏移上")])]
        #expect(ReplyReconcile.holdsReply(read, roundStart: 2, localRoundFailed: false,
                                          evidence: ReplyReconcile.evidence(of: closing)))
    }

    @Test func theClosingProseIsTheReplysOwnLastText() {
        let live = LiveTurn()
        #expect(live.closingProse == nil)
        live.appendText("Let me run them.")
        live.upsertToolCall(id: "t1", title: "Bash", kind: "execute", status: "completed",
                            rawInput: nil, rawOutput: "ok", content: nil)
        live.appendText(answer)
        // Reasoning after it, a sub-agent's words, and a blank run are not prose.
        live.appendThinking("Done, I think.")
        live.upsertToolCall(id: "a1", title: "Agent", kind: "think", status: "in_progress",
                            rawInput: nil, rawOutput: nil, content: nil)
        live.appendText("sub-agent chatter", parentToolUseId: "a1")
        live.appendText("  \n")
        #expect(live.closingProse == answer)
    }

    // MARK: Where the round starts

    private func start(_ read: [MessageTurn], offset: Int = 0, _ anchor: ReplyReconcile.RoundAnchor,
                       loadedEnd: Int, settled: Bool = true) -> Int? {
        ReplyReconcile.roundStart(in: read, offset: offset, anchor: anchor, loadedEnd: loadedEnd, settled: settled)
    }

    @Test func anExactAnchorIsTheRoundsIndexInTheRead() {
        let read = earlier + [user("Run the tests"), assistant(toolCall)]
        // Window opened at global 100; the round's prompt landed at 102.
        #expect(start(read, offset: 100, .at(102), loadedEnd: 102, settled: false) == 2)
        // Not grown past it: the read hasn't reached the round.
        #expect(start(earlier, offset: 100, .at(102), loadedEnd: 102) == nil)
    }

    /// The previous round was folded in from the stream as two turns, but the
    /// server holds it as three, and the reply being reconciled ends with the
    /// same words as that one did. Locally: `earlier` (2) + the folded prompt
    /// and reply (2), so `loadedEnd` is offset + 4 — the previous answer.
    private func readAfterAFoldedRound() -> [MessageTurn] {
        earlier + [user("Run the tests"), assistant([.text("On it.")] + toolCall), assistant([.text(answer)]),
                   user("Run the tests again"), assistant([.text("On it.")] + toolCall)]
    }

    private var againPrompt: ReplyReconcile.PromptMatch { .words(ReplyReconcile.promptWords(of: "Run the tests again")!) }

    @Test func aFoldedRoundsCountDoesNotPlaceTheNextRound() {
        let read = readAfterAFoldedRound()
        let evidence = ReplyReconcile.evidence(of: answer)
        for offset in [0, 240] {
            let anchor = ReplyReconcile.RoundAnchor.unplaced(from: offset + 2, prompt: againPrompt)
            // What the loaded count would have said: the round starts at 4.
            #expect(ReplyReconcile.holdsReply(read, roundStart: 4, localRoundFailed: false, evidence: evidence),
                    "the hole: the previous answer stands in for this one")
            let at = start(read, offset: offset, anchor, loadedEnd: offset + 4)
            #expect(at == 6)
            #expect(!ReplyReconcile.holdsReply(read, roundStart: at ?? 0, localRoundFailed: false, evidence: evidence))
            // Once this round's answer lands, it holds.
            let landed = read + [assistant([.text(answer)])]
            let landedAt = start(landed, offset: offset, anchor, loadedEnd: offset + 4)
            #expect(ReplyReconcile.holdsReply(landed, roundStart: landedAt ?? 0, localRoundFailed: false, evidence: evidence))
        }
    }

    @Test func anUnplacedRoundIsNotJudgedRightAtTheTurnsEnd() {
        let landed = readAfterAFoldedRound() + [assistant([.text(answer)])]
        #expect(start(landed, .unplaced(from: 2, prompt: againPrompt), loadedEnd: 4, settled: false) == nil)
    }

    @Test func aReadWithoutThisRoundsPromptIsNotTakenForIt() {
        // The read stops before this round's prompt: its last user turn is
        // the folded round's, whose reply ends the same way.
        let stale = Array(readAfterAFoldedRound().prefix(5))
        #expect(start(stale, .unplaced(from: 2, prompt: againPrompt), loadedEnd: 4) == nil)
        // A folded round's steer persisted as a user turn is no prompt either.
        let steered = earlier + [user("Run the tests"), assistant([.text("Running.")]), user("use pnpm"),
                                 assistant([.text(answer)])]
        #expect(start(steered, .unplaced(from: 2, prompt: againPrompt), loadedEnd: 4) == nil)
        // Nor is a user turn from before the folded rounds.
        let none = earlier + [assistant([.text(answer)]), assistant([.text("more")]), assistant(toolCall)]
        #expect(start(none, .unplaced(from: 2, prompt: againPrompt), loadedEnd: 4) == nil)
    }

    @Test func aPromptStoppedBeforeItWasSentLeavesNoDebt() {
        // Folded locally: [the unsent prompt] — the server never got it. This
        // round's read holds just its own prompt and reply.
        let read = earlier + [user("Run the tests again"), assistant([.text(answer)])]
        let at = start(read, .unplaced(from: 2, prompt: againPrompt), loadedEnd: 3)
        #expect(at == 3)
        #expect(ReplyReconcile.holdsReply(read, roundStart: at ?? 0, localRoundFailed: false,
                                          evidence: ReplyReconcile.evidence(of: answer)))
    }

    @Test func aPromptTheAgentWrapsStillReadsAsSent() {
        let read = earlier + [user("x", id: "folded"), assistant([.text("Ok.")]),
                              user("<command-name>/review</command-name>\n<command-args>src</command-args>"),
                              assistant([.text(answer)])]
        #expect(start(read, .unplaced(from: 2, prompt: .words(ReplyReconcile.promptWords(of: "/review src")!)), loadedEnd: 4) == 5)
    }

    @Test func withoutAPromptOfItsOwnTheRoundFollowsTheLastUserTurn() {
        // A watched turn: the prompt was never this screen's to send.
        let read = readAfterAFoldedRound()
        #expect(start(read, .unplaced(from: 2, prompt: .notOurs), loadedEnd: 4) == 6)
        // And the growth floor still holds.
        #expect(start(read, .unplaced(from: 2, prompt: .notOurs), loadedEnd: 7) == nil)
    }

    @Test func theNewestRoundStartsAfterTheLastUserTurn() {
        let read = readAfterAFoldedRound()
        #expect(ReplyReconcile.lastRoundStart(in: read, offset: 0, from: 2) == 6)
        #expect(ReplyReconcile.lastRoundStart(in: read, offset: 100, from: 102) == 6)
        // No user turn from `from` on: the round is all of it.
        #expect(ReplyReconcile.lastRoundStart(in: read, offset: 0, from: 6) == 6)
        #expect(ReplyReconcile.lastRoundStart(in: read, offset: 0, from: 99) == read.count)
        // The settled re-read looks there for the latest folded reply.
        #expect(!ReplyReconcile.holdsProse(read, from: 6, evidence: ReplyReconcile.evidence(of: answer)!))
        #expect(ReplyReconcile.holdsProse(read + [assistant([.text(answer)])], from: 6,
                                          evidence: ReplyReconcile.evidence(of: answer)!))
    }

    @Test func aPromptIsItsWordsInOrder() {
        #expect(ReplyReconcile.promptWords(of: "Run the  tests\nagain!") == ["run", "the", "tests", "again"])
        #expect(ReplyReconcile.promptWords(of: "  ") == nil)
        #expect(ReplyReconcile.promptWords(of: nil) == nil)
        let long = (1...20).map { "w\($0)" }.joined(separator: " ")
        #expect(ReplyReconcile.promptWords(of: long)?.first == "w9")
        #expect(ReplyReconcile.promptWords(of: "跑一下测试，然后提交")?.count == 1)
    }

    @Test func notesSteeredIntoThisRoundStayInIt() {
        // The server kept this round's steered note as a user turn after the
        // prompt; the round is everything after the prompt.
        let folded = earlier + [user("Run the tests"), assistant([.text(answer)])]
        let written = folded + [user("Run the tests again"), assistant([.text("Running.")]), user("use pnpm"),
                                assistant(toolCall)]
        let anchor = ReplyReconcile.RoundAnchor.unplaced(from: 2, prompt: againPrompt)
        let evidence = ReplyReconcile.evidence(of: answer)
        let at = start(written, anchor, loadedEnd: 4)
        #expect(at == 5)
        #expect(!ReplyReconcile.holdsReply(written, roundStart: at ?? 0, localRoundFailed: false, evidence: evidence))
        let landed = written + [assistant([.text(answer)])]
        #expect(ReplyReconcile.holdsReply(landed, roundStart: start(landed, anchor, loadedEnd: 4) ?? 0,
                                          localRoundFailed: false, evidence: evidence))
    }

    @Test func aPromptAFoldedTurnAlsoSaysIsNotPlaced() {
        // Codex's case: the folded round asked the same and a note followed;
        // a stale read holds only that round, whose reply began the same way.
        let foldedLocally = [user("Run the tests", id: "pending-1"), assistant([.text("Running.")]),
                             user("use pnpm", id: "steer-n1"), assistant([.text("Running.")])]
        let sent = user("Run the tests", id: "pending-2")
        #expect(ReplyReconcile.promptMatch(sent: sent, folded: foldedLocally) == .unidentifiable)
        let stale = earlier + [user("Run the tests"), assistant([.text("Running.")]), user("use pnpm"),
                               assistant([.text("Running.")]), assistant(toolCall)]
        #expect(start(stale, .unplaced(from: 2, prompt: .unidentifiable), loadedEnd: 6) == nil)
        // A note that says the prompt's words counts as saying it.
        let noted = [user("x", id: "pending-1"), user("now run the tests", id: "steer-n2")]
        #expect(ReplyReconcile.promptMatch(sent: sent, folded: noted) == .unidentifiable)
    }

    @Test func aPromptIsMatchedByItsOwnWords() {
        let folded = [user("Run the tests", id: "pending-1"), assistant([.text(answer)])]
        let sent = MessageTurn(id: "pending-2", role: .user,
                               blocks: [.text("Run the tests again"), .image(ImageData(data: "", mimeType: "image/png", uri: nil))],
                               timestamp: at)
        #expect(ReplyReconcile.promptMatch(sent: sent, folded: folded) == againPrompt)
        // Not this screen's send, and one with no words.
        #expect(ReplyReconcile.promptMatch(sent: nil, folded: folded) == .notOurs)
        let image = MessageTurn(id: "pending-3", role: .user, blocks: [.image(ImageData(data: "", mimeType: "image/png", uri: nil))],
                                timestamp: at)
        #expect(ReplyReconcile.promptMatch(sent: image, folded: folded) == .unidentifiable)
        #expect(start(readAfterAFoldedRound(), .unplaced(from: 2, prompt: .unidentifiable), loadedEnd: 4) == nil)
    }
}
