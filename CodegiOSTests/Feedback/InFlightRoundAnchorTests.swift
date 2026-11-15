import Foundation
import Testing
@testable import Codeg

/// A reattach hides the persisted partial copy of the reply its live turn
/// shows. The round starts at the server's `in_flight_user_turn_id` — its
/// EARLIEST prompt — so a message steered in mid-turn, persisted as a user
/// turn of its own, doesn't leave the reply's first part drawn twice.
@MainActor
struct InFlightRoundAnchorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func user(_ id: String) -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text("q \(id)")], timestamp: t0)
    }

    private func reply(_ id: String) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: [.text("a \(id)")], timestamp: t0)
    }

    /// u1 → a1 (done) · u2 prompt → a2 partial · u3 steered → a3 partial.
    private var steeredRound: [MessageTurn] {
        [user("u1"), reply("a1"), user("u2"), reply("a2"), user("u3"), reply("a3")]
    }

    private func replyIDs(_ turns: [MessageTurn], inFlight: String?) -> Set<String> {
        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .claudeCode,
                                                      suppressInFlight: true, inFlightUserTurnId: inFlight)
        return Set(nodes.compactMap { node in
            ["a1", "a2", "a3"].first { node.id.hasPrefix($0) }
        })
    }

    @Test func theRoundIsHiddenFromItsFirstPrompt() {
        #expect(replyIDs(steeredRound, inFlight: "u2") == ["a1"])
    }

    @Test func userTurnsStayInTheRound() {
        let nodes = TranscriptTimeline.buildPersisted(turns: steeredRound, pending: [], agent: .claudeCode,
                                                      suppressInFlight: true, inFlightUserTurnId: "u2")
        #expect(["u1", "u2", "u3"].allSatisfy { id in nodes.contains { $0.id == id } })
    }

    @Test func withoutTheAnchorTheNewestPromptIsTheGuess() {
        #expect(replyIDs(steeredRound, inFlight: nil) == ["a1", "a2"])
        // Stamped, but above the loaded window.
        #expect(replyIDs(steeredRound, inFlight: "u0") == ["a1", "a2"])
    }

    @Test func nothingIsHiddenWithoutALiveTurnOwningTheReply() {
        let nodes = TranscriptTimeline.buildPersisted(turns: steeredRound, pending: [], agent: .claudeCode,
                                                      suppressInFlight: false, inFlightUserTurnId: "u2")
        #expect(Set(nodes.compactMap { n in ["a1", "a2", "a3"].first { n.id.hasPrefix($0) } }) == ["a1", "a2", "a3"])
    }

    @Test func theAnchorOnlyMatchesAUserTurn() {
        #expect(TranscriptTimeline.inFlightPromptIndex(steeredRound, inFlightUserTurnId: "u2") == 2)
        #expect(TranscriptTimeline.inFlightPromptIndex(steeredRound, inFlightUserTurnId: "a2") == 4)
        #expect(TranscriptTimeline.inFlightPromptIndex([reply("a1")], inFlightUserTurnId: nil) == nil)
    }
}
