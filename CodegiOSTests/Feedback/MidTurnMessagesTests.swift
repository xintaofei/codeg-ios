import Foundation
import Testing
@testable import Codeg

/// Sending while a turn runs: the queue, the live-feedback notes, and the
/// steered message splitting the live reply (codeg 0.44, web
/// `useMessageQueue` / `useSessionFeedback` / `STEERING_MESSAGE`).
@Suite struct MessageQueueTests {
    private func prompt(_ text: String) -> QueuedPrompt { QueuedPrompt(text: text) }

    @Test func sendsOldestFirst() {
        var queue = MessageQueue()
        queue.enqueue(prompt("a"))
        queue.enqueue(prompt("b"))
        #expect(queue.dequeue()?.text == "a")
        #expect(queue.dequeue()?.text == "b")
        #expect(queue.dequeue() == nil)
    }

    @Test func aBouncedHeadRetriesBeforeWhatWasBehindIt() {
        var queue = MessageQueue()
        queue.enqueue(prompt("a"))
        queue.enqueue(prompt("b"))
        let head = queue.dequeue()!
        queue.requeueFront(head)
        #expect(queue.items.map(\.text) == ["a", "b"])
    }

    @Test func aRowCanGoNextOrLeave() {
        var queue = MessageQueue()
        let a = prompt("a"), b = prompt("b"), c = prompt("c")
        [a, b, c].forEach { queue.enqueue($0) }
        queue.moveToFront(c.id)
        #expect(queue.items.map(\.text) == ["c", "a", "b"])
        queue.moveToFront(c.id)   // already first
        #expect(queue.items.map(\.text) == ["c", "a", "b"])
        #expect(queue.remove(a.id)?.text == "a")
        #expect(queue.remove(a.id) == nil)
        #expect(queue.items.map(\.text) == ["c", "b"])
    }

    @Test func onlyABounceDelaysTheFlush() {
        #expect(MessageQueue.flushDelay(sinceBounce: nil) == .zero)
        #expect(MessageQueue.flushDelay(sinceBounce: .milliseconds(200)) == .milliseconds(800))
        #expect(MessageQueue.flushDelay(sinceBounce: .seconds(1)) == .zero)
        #expect(MessageQueue.flushDelay(sinceBounce: .seconds(5)) == .zero)
        // A bounce stamped "in the future" counts as just now — never longer.
        #expect(MessageQueue.flushDelay(sinceBounce: .milliseconds(-300)) == .seconds(1))
    }
}

@Suite struct FeedbackNotesTests {
    private func note(_ id: String, _ status: String = "pending") -> FeedbackItem {
        FeedbackItem(id: id, text: "note \(id)", status: status)
    }

    @Test func liveCopiesWinOverTheSnapshot() {
        var notes = FeedbackNotes()
        notes.submitted(note("a"))
        notes.consumed(ids: ["a"], at: "t1")
        // A snapshot taken before the consume still says pending.
        notes.hydrate([note("a"), note("b")])
        #expect(notes.notes.map(\.id) == ["a", "b"])
        #expect(notes.notes.first?.isDelivered == true)
    }

    @Test func aReadMissedDuringASocketGapIsTakenFromTheSnapshot() {
        var notes = FeedbackNotes()
        notes.submitted(note("a"))
        // The consume went by while the socket was down; the snapshot knows.
        notes.hydrate([FeedbackItem(id: "a", text: "note a", status: "delivered", deliveredAt: "t2")])
        #expect(notes.notes.first?.isDelivered == true)
        #expect(notes.notes.first?.deliveredAt == "t2")
        #expect(notes.visible(turnRunning: false, adopted: []).isEmpty, "never offered for resending")
    }

    @Test func aConsumeThatRacesAheadOfItsNoteIsHonoured() {
        var notes = FeedbackNotes()
        notes.consumed(ids: ["a"], at: "t1")
        notes.submitted(note("a"))
        #expect(notes.notes.first?.isDelivered == true)
        #expect(notes.notes.first?.deliveredAt == "t1")
    }

    @Test func submittingTwiceKeepsOneRow() {
        var notes = FeedbackNotes()
        notes.submitted(note("a"))   // this client's own submit reply
        notes.submitted(note("a"))   // the broadcast
        #expect(notes.notes.count == 1)
    }

    @Test func aRetiredRowStaysRetiredAcrossARehydrate() {
        var notes = FeedbackNotes()
        notes.submitted(note("a"))
        notes.dismiss("a")
        notes.hydrate([note("a")])
        notes.submitted(note("a"))
        #expect(notes.notes.isEmpty)
    }

    @Test func aNewTurnClearsEverything() {
        var notes = FeedbackNotes()
        notes.submitted(note("a"))
        notes.consumed(ids: ["b"], at: "t")
        notes.newTurn()
        #expect(notes.notes.isEmpty)
        notes.submitted(note("b"))
        #expect(notes.notes.first?.isDelivered == false, "the old tombstone went with its turn")
    }

    @Test func afterTheTurnOnlyUnreadNotesRemain() {
        var notes = FeedbackNotes()
        notes.submitted(note("a"))
        notes.submitted(note("b", "delivered"))
        notes.submitted(note("c", "delivered"))
        #expect(notes.visible(turnRunning: true, adopted: ["c"]).map(\.id) == ["a", "b"],
                "a note the transcript shows as a message is not drawn twice")
        #expect(notes.visible(turnRunning: false, adopted: []).map(\.id) == ["a"])
    }
}

@Suite struct FeedbackWireTests {
    @Test func noActiveTurnIsRecognisedByCodeOrText() {
        #expect(TurnRejection.isNoActiveTurn(APIError.server(status: 409, code: "no_active_turn", message: "x")))
        #expect(TurnRejection.isNoActiveTurn(APIError.server(status: 400, code: nil, message: "no active turn to send feedback to")))
        #expect(!TurnRejection.isNoActiveTurn(APIError.turnInProgress))
        #expect(!TurnRejection.isNoActiveTurn(APIError.server(status: 400, code: "feedback_disabled", message: "live feedback is disabled")))
    }

    @Test func feedbackEventsDecode() throws {
        let submitted = try CodegJSON.decoder.decode(AcpEvent.self, from: Data(
            #"{"type":"feedback_submitted","item":{"id":"n1","text":"use tabs","created_at":"2026-11-14T00:00:00Z","status":"delivered","delivered_at":"2026-11-14T00:00:00Z"}}"#.utf8))
        guard case .feedbackSubmitted(let item) = submitted else { Issue.record("decoded \(submitted)"); return }
        #expect(item.id == "n1" && item.text == "use tabs" && item.isDelivered)

        let consumed = try CodegJSON.decoder.decode(AcpEvent.self, from: Data(
            #"{"type":"feedback_consumed","ids":["n1","n2"],"delivered_at":"2026-11-14T00:00:01Z"}"#.utf8))
        guard case .feedbackConsumed(let ids, let at) = consumed else { Issue.record("decoded \(consumed)"); return }
        #expect(ids == ["n1", "n2"])
        #expect(at == "2026-11-14T00:00:01Z")
    }

    @Test func theSnapshotCarriesNotesAndChannels() throws {
        let snap = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(
            #"{"status":"prompting","feedback":[{"id":"n1","text":"hi","status":"pending"}],"feedback_tool_available":true,"native_steering_available":false}"#.utf8))
        #expect(snap.feedback.map(\.id) == ["n1"])
        #expect(snap.feedbackToolAvailable)
        #expect(!snap.nativeSteeringAvailable)

        let old = try CodegJSON.decoder.decode(SessionSnapshot.self, from: Data(#"{"selectors_ready":true}"#.utf8))
        #expect(old.nativeSteeringAvailable == nil, "an older server's silence is not a downgrade")
    }
}

@MainActor
@Suite struct SteeredReplyTests {
    private func steeredLive() -> LiveTurn {
        let live = LiveTurn()
        live.appendText("Looking at it")
        live.insertSteering(SteeredMessage(id: "n1", text: "use tabs", at: Date()))
        live.insertSteering(SteeredMessage(id: "n1", text: "use tabs", at: Date()))   // the broadcast, again
        live.appendText("Switching to tabs")
        live.flushAllText()
        return live
    }

    @Test func aSteerSplitsTheFoldedReply() {
        let turns = steeredLive().snapshotAsMessageTurns()
        #expect(turns.map(\.role) == [.assistant, .user, .assistant])
        #expect(turns[1].id == "steer-n1")
        #expect(Set(turns.map(\.id)).count == 3, "every piece keeps its own identity")
    }

    @Test func aFailedSteeredRoundSaysWhyAtItsEnd() {
        let live = steeredLive()
        live.errorMessage = "Overloaded"
        let turns = live.snapshotAsMessageTurns()
        #expect(turns.last?.blocks.contains { if case .turnError = $0 { return true }; return false } == true)
        #expect(turns.first?.blocks.contains { if case .turnError = $0 { return true }; return false } == false)
    }

    @Test func theLiveTimelineShowsTheSteerAsAUserMessage() {
        let live = steeredLive()
        let nodes = TranscriptTimeline.buildLive(live, agent: .claudeCode)
        let users = nodes.filter { if case .user = $0.content { return true }; return false }
        #expect(users.map(\.id) == ["steer-n1"])
        #expect(live.steeredIDs == ["n1"])
        // Its reply starts out thinking until it has words of its own.
        let fresh = LiveTurn()
        fresh.appendText("Before")
        fresh.insertSteering(SteeredMessage(id: "n2", text: "stop", at: Date()))
        let freshNodes = TranscriptTimeline.buildLive(fresh, agent: .claudeCode)
        #expect(freshNodes.contains { node in
            if case .thinking = node.content { return node.id.hasSuffix("~n2#thinking") }
            return false
        })
    }
}
