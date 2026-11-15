import Foundation
import Testing
@testable import Codeg

// A goal's Pause / Clear (web `useAdvertisedGoalActions` + `goal-tool-call`
// controls; Android cd31131 / d3edfac).

private func snapshot(seq: UInt64, connection: String = "c1", _ extra: [String: Any] = [:]) throws -> LiveSessionSnapshot {
    var json: [String: Any] = ["connection_id": connection, "status": "connected", "event_seq": seq]
    json.merge(extra) { _, new in new }
    return try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
}

@Suite struct GoalActionsDecodingTests {
    @Test func aListIsKnownNullIsUndecidedAbsentIsTheLegacyPair() throws {
        #expect(try snapshot(seq: 1, ["goal_actions": ["set", "clear"]]).runs.goalActions == ["set", "clear"])
        #expect(try snapshot(seq: 1, ["goal_actions": NSNull()]).runs.goalActions == nil)
        #expect(try snapshot(seq: 1).runs.goalActions == ["pause", "clear"])
        #expect(try snapshot(seq: 1, ["goal_actions": []]).runs.goalActions == [])
    }

    @Test func aSnapshotResponseBodyReadsTheSame() {
        #expect(GoalActions.decode(Data(#"{"connection_id":"c1","goal_actions":["clear"]}"#.utf8)) == ["clear"])
        #expect(GoalActions.decode(Data(#"{"connection_id":"c1","goal_actions":null}"#.utf8)) == nil)
        #expect(GoalActions.decode(Data(#"{"connection_id":"c1"}"#.utf8)) == ["pause", "clear"])
    }
}

@MainActor
@Suite struct GoalActionsStateTests {
    @Test func undecidedAsksForAReadAndALaterAnswerIsKept() throws {
        let runs = ConnectionRunsModel()
        var asked: [String] = []
        runs.onGoalActionsUndecided = { asked.append($0) }
        runs.hydrate(try snapshot(seq: 1, ["goal_actions": NSNull()]), connection: "c1")
        #expect(runs.goalActions == nil)
        #expect(asked == ["c1"])
        runs.adoptGoalActions(["set", "clear"], connection: "other")
        #expect(runs.goalActions == nil, "an answer about another connection changes nothing")
        runs.adoptGoalActions(["set", "clear"], connection: "c1")
        #expect(runs.goalActions == ["set", "clear"])
        // Fixed for the connection's life.
        runs.hydrate(try snapshot(seq: 5, ["goal_actions": ["pause"]]), connection: "c1")
        #expect(runs.goalActions == ["set", "clear"])
        #expect(asked == ["c1"])
    }

    @Test func anotherConnectionStartsUndecidedAgain() throws {
        let runs = ConnectionRunsModel()
        runs.hydrate(try snapshot(seq: 1, ["goal_actions": ["pause", "clear"]]), connection: "c1")
        runs.hydrate(try snapshot(seq: 1, connection: "c2", ["goal_actions": NSNull()]), connection: "c2")
        #expect(runs.goalActions == nil)
        runs.hydrate(try snapshot(seq: 2, connection: "c2", ["goal_actions": ["clear"]]), connection: "c2")
        #expect(runs.goalActions == ["clear"])
        runs.connectionGone("c2")
        #expect(runs.goalActions == nil)
    }
}

@Suite struct GoalControlOfferTests {
    private let live = GoalControl(onControl: { _, _ in }, actions: ["pause", "clear"], currentGoalID: "g2")

    @Test func pauseWhileActiveClearWhileActiveOrPaused() {
        #expect(live.offers(goalID: "g2", status: .active) == (true, true))
        #expect(live.offers(goalID: "g2", status: .paused) == (false, true))
        #expect(live.offers(goalID: "g2", status: .complete) == (false, false))
        #expect(live.offers(goalID: "g2", status: nil) == (false, false))
    }

    @Test func aGoalWithAControlOnItsWayOffersNoSecond() {
        var pending = live
        pending.pendingGoalID = "g2"
        #expect(pending.offers(goalID: "g2", status: .active) == (false, false))
    }

    @Test func onlyTheCurrentGoalOnALiveConnectionWithTheAction() {
        #expect(live.offers(goalID: "g1", status: .active) == (false, false), "an earlier goal")
        var offline = live
        offline.onControl = nil
        #expect(offline.offers(goalID: "g2", status: .active) == (false, false))
        // claude's goal extension: no pause.
        let claude = GoalControl(onControl: { _, _ in }, actions: ["set", "clear"], currentGoalID: "g2")
        #expect(claude.offers(goalID: "g2", status: .active) == (false, true))
        #expect(GoalControl.none.offers(goalID: "g2", status: .active) == (false, false))
    }
}

@MainActor
@Suite struct LatestGoalTests {
    @Test func theLatestGoalIsFoundEvenWhenItsReplyIsFolded() {
        let date = Date()
        func goalTurn(_ id: String, _ objective: String, status: String) -> [MessageTurn] {
            [MessageTurn(id: "u-\(id)", role: .user, blocks: [.text("/goal \(objective)")], timestamp: date),
             MessageTurn(id: "a-\(id)", role: .assistant, blocks: [
                .toolUse(id: id, name: "create_goal", inputPreview: #"{"objective":"\#(objective)"}"#,
                         status: .unknown, meta: nil),
                .toolResult(id: id, outputPreview: #"{"goal":{"objective":"\#(objective)","status":"\#(status)"}}"#,
                            isError: false, agentStats: nil),
                .text("Working on it."),
             ], timestamp: date)]
        }
        let built = TranscriptTimeline.buildPersisted(
            turns: goalTurn("g1", "Tidy", status: "paused") + goalTurn("g2", "Bump", status: "active"),
            pending: [], agent: .codex, suppressInFlight: false)
        #expect(TranscriptTimeline.latestGoalID(built) == "g2")
        // Folded (a fresh screen), neither goal row shows — the latest is still g2.
        let folded = ReplyFolding.apply(built, store: ReplyFoldStore())
        #expect(!folded.contains { if case .goal = $0.content { return true }; return false })
    }
}
