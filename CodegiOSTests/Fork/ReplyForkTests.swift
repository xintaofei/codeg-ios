import Foundation
import Testing
@testable import Codeg

/// "Fork from here" (codeg 0.44): which turn a reply's footer forks at, when
/// it may offer to at all, and the wire. The `isForkPointUnnamed` cases are
/// ported from the web's `message-list-view.test.tsx`; the `markThreadTail`
/// rule (a failed round's closing line is stepped over) from the same file.
@MainActor
@Suite struct ReplyForkPointTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func user(_ id: String, _ text: String = "q") -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text(text)], timestamp: t0)
    }

    private func reply(_ id: String, _ text: String = "a") -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: [.text(text)], timestamp: t0)
    }

    private func points(_ turns: [MessageTurn], pending: [MessageTurn] = []) -> [ReplyForkPoint] {
        TranscriptTimeline.buildPersisted(turns: turns, pending: pending, agent: .claudeCode,
                                          suppressInFlight: false, forkPoints: true)
            .compactMap(\.forkPoint)
    }

    @Test func aMergedReplyForksAtItsLastTurn() {
        let turns = [user("u1"), reply("a1"), reply("a2"), user("u2"), reply("a3")]
        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .claudeCode,
                                                      suppressInFlight: false, forkPoints: true)
        let footer = nodes.first { $0.forkPoint?.turnID == "a2" }
        #expect(footer?.id == "a1#footer", "the row keeps the merged turn's (first) id")
        #expect(points(turns) == [
            ReplyForkPoint(turnID: "a2", isThreadTail: false),
            ReplyForkPoint(turnID: "a3", isThreadTail: true),
        ])
    }

    @Test func onlyTheMainTranscriptAsksForForkPoints() {
        let nodes = TranscriptTimeline.buildPersisted(turns: [user("u1"), reply("a1")], pending: [],
                                                      agent: .claudeCode, suppressInFlight: false)
        #expect(nodes.allSatisfy { $0.forkPoint == nil })
    }

    @Test func aMessageOnItsWayEndsTheThreadNotTheReply() {
        let pending = MessageTurn(id: "pending-1", role: .user, blocks: [.text("next")], timestamp: t0)
        #expect(points([user("u1"), reply("a1")], pending: [pending]).map(\.isThreadTail) == [false])
    }

    @Test func aFailedRoundsClosingLineIsSteppedOver() {
        let failure = MessageTurn(id: "s1", role: .system, blocks: [.turnError("API Error: 503")], timestamp: t0)
        let silent = MessageTurn(id: "s2", role: .system, blocks: [], timestamp: t0)
        #expect(ReplyForkPoint.threadTailIndex([user("u1"), reply("a1"), failure, silent]) == 1)
        #expect(points([user("u1"), reply("a1"), failure]).map(\.isThreadTail) == [true])
    }

    @Test func aSystemNoteOrAMessageAfterTheReplyMeansNoTail() {
        let note = MessageTurn(id: "s1", role: .system, blocks: [.text("Context compacted")], timestamp: t0)
        #expect(ReplyForkPoint.threadTailIndex([user("u1"), reply("a1"), note]) == nil)
        #expect(ReplyForkPoint.threadTailIndex([user("u1"), reply("a1"), user("u2")]) == nil)
        #expect(ReplyForkPoint.threadTailIndex([]) == nil)
    }

    // MARK: - isForkPointUnnamed (web), on iOS's id scheme

    @Test func withholdsALiveNamedReplyThatIsNotTheThreadsLastItem() {
        #expect(ReplyForkPoint(turnID: "live-7", isThreadTail: false).request(agent: .claudeCode) == nil)
        #expect(ReplyForkPoint(turnID: "live-7~1", isThreadTail: false).request(agent: .codex) == nil)
        #expect(ReplyForkPoint(turnID: "pending-3", isThreadTail: false).request(agent: .claudeCode) == nil)
    }

    @Test func allowsOneAtTheEndOfTheThreadWhereTheTailIsTheForkPoint() {
        // Never sends the client's own id: the tail is named by naming nothing.
        #expect(ReplyForkPoint(turnID: "live-7", isThreadTail: true).request(agent: .claudeCode)
                == ReplyForkPoint.Request(forkFromTurnId: nil))
    }

    @Test func leavesParserNamedHistoryAlone() {
        #expect(ReplyForkPoint(turnID: "turn-4", isThreadTail: false).request(agent: .claudeCode)
                == ReplyForkPoint.Request(forkFromTurnId: "turn-4"))
        #expect(ReplyForkPoint(turnID: "turn-4", isThreadTail: true).request(agent: .claudeCode)
                == ReplyForkPoint.Request(forkFromTurnId: "turn-4"))
    }

    @Test func aReplyThatEndedOnAToolCallIsOfferedOnlyAtTheTail() throws {
        // The backend names a Codex point by its text's fingerprint alone, and
        // a Claude one by that or a message id this client never sees.
        let toolOnly = MessageTurn(id: "a1", role: .assistant, blocks: [
            .text("  "),
            .toolUse(id: "c1", name: "Bash", inputPreview: #"{"command":"ls"}"#, status: .unknown, meta: nil),
            .toolResult(id: "c1", outputPreview: "a.txt", isError: false, agentStats: nil),
        ], timestamp: t0)
        #expect(!ReplyForkPoint.hasForkableText(toolOnly))
        #expect(ReplyForkPoint.hasForkableText(reply("a2", "Done.")))

        let all = points([user("u1"), toolOnly, user("u2"), reply("a2")])
        let first = try #require(all.first)
        #expect(first.turnID == "a1")
        #expect(!first.hasText)
        #expect(first.request(agent: .codex) == nil)
        #expect(first.request(agent: .claudeCode) == nil)
        #expect(ReplyForkPoint(turnID: "a1", isThreadTail: true, hasText: false).request(agent: .codex)
                == ReplyForkPoint.Request(forkFromTurnId: "a1"), "the tail is the fork point either way")
    }

    @Test func anAgentThatOnlyForksAtTheTailIsOfferedOnlyTheLastReply() {
        #expect(ReplyForkPoint(turnID: "turn-4", isThreadTail: false).request(agent: .gemini) == nil)
        #expect(ReplyForkPoint(turnID: "turn-4", isThreadTail: true).request(agent: .gemini)
                == ReplyForkPoint.Request(forkFromTurnId: nil))
        #expect(ReplyForkPoint.canForkAtTurn(.other(wire: "deepseek")))
        #expect(ReplyForkPoint.canForkAtTurn(.codex))
        #expect(!ReplyForkPoint.canForkAtTurn(.grok))
    }
}

@Suite struct ForkWireTests {
    @Test func theResultIsCamelCaseOnTheWire() throws {
        let result = try CodegJSON.decoder.decode(ForkResult.self, from: Data(
            #"{"forkedSessionId":"s2","originalSessionId":"s1","siblingConversationId":42}"#.utf8))
        #expect(result == ForkResult(forkedSessionId: "s2", originalSessionId: "s1", siblingConversationId: 42))
    }

    @Test func theBodySendsEveryFieldNullsIncluded() throws {
        let data = try CodegJSON.encoder.encode(AcpForkBody(
            connectionId: "c1", conversationId: 7, folderId: nil, forkFromTurnId: nil))
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try #require(json as? [String: Any])
        #expect(object["connectionId"] as? String == "c1")
        #expect(object["conversationId"] as? Int == 7)
        #expect(object["folderId"] is NSNull)
        #expect(object["forkFromTurnId"] is NSNull, "null forks at the tail")
    }

    @Test func theSupportEventDecodes() throws {
        let event = try CodegJSON.decoder.decode(AcpEvent.self, from: Data(
            #"{"type":"fork_supported","supported":true}"#.utf8))
        #expect(event == .forkSupported(supported: true))
        let malformed = try CodegJSON.decoder.decode(AcpEvent.self, from: Data(#"{"type":"fork_supported"}"#.utf8))
        #expect(malformed == .unknown(type: "fork_supported"))
    }

    @Test func snapshotsCarryTheFlag() throws {
        let live = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(
            #"{"status":"connected","fork_supported":true}"#.utf8))
        #expect(live.forkSupported == true)
        let older = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(#"{"status":"connected"}"#.utf8))
        #expect(older.forkSupported == nil)
        let byConversation = try CodegJSON.decoder.decode(SessionSnapshot.self, from: Data(
            #"{"selectors_ready":true,"status":"prompting","fork_supported":false}"#.utf8))
        #expect(byConversation.forkSupported == false)
    }

    @Test func onlyAnInitializedConnectionsFlagIsAnAnswer() {
        #expect(ForkSupport.reading(status: .connecting, supported: false) == nil,
                "false until initialize has run")
        #expect(ForkSupport.reading(status: .connected, supported: false) == false)
        #expect(ForkSupport.reading(status: .prompting, supported: true) == true)
        #expect(ForkSupport.reading(status: .error, supported: false) == nil)
        #expect(ForkSupport.reading(status: nil, supported: true) == nil)
        #expect(ForkSupport.reading(status: .connected, supported: nil) == nil)
    }
}

@Suite struct ForkFailureTests {
    @Test func aVanishedConnectionIsA500NotA404() {
        #expect(ForkFailure.isConnectionGone(APIError.server(
            status: 500, code: "task_execution_failed", message: "connection not found: conn-9")))
        #expect(ForkFailure.isConnectionGone(APIError.server(status: 404, code: nil, message: "x")))
        #expect(!ForkFailure.isConnectionGone(APIError.turnInProgress))
        #expect(!ForkFailure.isConnectionGone(APIError.server(
            status: 500, code: "task_execution_failed", message: "ACP protocol error: session/fork failed: nope")))
        #expect(!ForkFailure.isConnectionGone(CancellationError()))
    }

    @Test func anAgentWithoutForkIsRecognised() {
        let error = APIError.server(status: 500, code: "task_execution_failed",
                                    message: "ACP protocol error: This agent does not support session/fork")
        #expect(ForkFailure.isUnsupported(error))
        #expect(ForkFailure.message(error) == "This agent does not support session/fork")
        #expect(!ForkFailure.isUnsupported(APIError.turnInProgress))
    }

    @Test func aRereadShowsTheForkOnceTheRowAndItsTranscriptAreThere() throws {
        func detail(externalId: String, total: Int) throws -> ConversationDetail {
            try CodegJSON.decoder.decode(ConversationDetail.self, from: Data("""
            {"summary":{"id":1,"folder_id":2,"title":"[Fork] t","agent_type":"claude_code",
            "status":"pending_review","message_count":2,"external_id":"\(externalId)",
            "created_at":"2026-11-14T00:00:00Z","updated_at":"2026-11-14T00:00:00Z"},
            "turns":[],"turns_offset":0,"turns_total":\(total),"prefix_hash":"cbf29ce484222325"}
            """.utf8))
        }
        let forked = try detail(externalId: "s2", total: 4)
        let notWrittenYet = try detail(externalId: "s2", total: 0)
        let stillTheOriginal = try detail(externalId: "s1", total: 4)
        #expect(ForkRefetch.isApplied(forked, forkedSessionId: "s2"))
        #expect(!ForkRefetch.isApplied(notWrittenYet, forkedSessionId: "s2"),
                "the forked transcript isn't written yet")
        #expect(!ForkRefetch.isApplied(stillTheOriginal, forkedSessionId: "s2"))
    }
}
