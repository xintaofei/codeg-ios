import Foundation
import Testing
@testable import Codeg

/// The out-of-turn overlay (web `background-overlay.test.ts`, Android
/// `BackgroundWorkTest`) and the launch card's lifecycle marker.
struct BackgroundOverlayTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func turn(_ id: String, _ role: TurnRole = .assistant, at seconds: Double,
                      _ blocks: [ContentBlock] = [.text("hi")]) -> MessageTurn {
        MessageTurn(id: id, role: role, blocks: blocks, timestamp: t0.addingTimeInterval(seconds))
    }

    @Test func aBatchUpsertsByIdAndIsBounded() {
        var overlay = BackgroundOverlays.upsert([], turns: [turn("bg-1", at: 1)], watermark: 10)
        overlay = BackgroundOverlays.upsert(overlay, turns: [turn("bg-1", at: 1, [.text("grown")]), turn("bg-2", at: 2)],
                                            watermark: 20)
        #expect(overlay.map(\.turn.id) == ["bg-1", "bg-2"])
        #expect(overlay[0].turn.blocks == [.text("grown")])
        #expect(overlay.map(\.watermark) == [20, 20])
        let many = (0..<250).map { turn("t\($0)", at: Double($0)) }
        let capped = BackgroundOverlays.upsert([], turns: many, watermark: 1)
        #expect(capped.count == BackgroundOverlays.hardCap)
        #expect(capped.first?.turn.id == "t50", "the newest are kept")
    }

    @Test func aReadRetiresWhatItCovers() {
        let overlay = [BackgroundOverlayEntry(turn: turn("a", at: 1), watermark: 10),
                       BackgroundOverlayEntry(turn: turn("b", at: 5), watermark: 30)]
        #expect(BackgroundOverlays.retire(overlay, watermark: 20, uncoveredMaxTs: nil)?.map(\.turn.id) == ["b"])
        #expect(BackgroundOverlays.retire(overlay, watermark: 30, uncoveredMaxTs: nil)?.isEmpty == true)
        #expect(BackgroundOverlays.retire(overlay, watermark: 5, uncoveredMaxTs: nil) == nil, "nothing covered")
        #expect(BackgroundOverlays.retire(overlay, watermark: nil, uncoveredMaxTs: nil) == nil, "no watermark, no proof")
        // A window only covers what is strictly newer than everything above it.
        let windowed = BackgroundOverlays.retire(overlay, watermark: 40, uncoveredMaxTs: t0.addingTimeInterval(3))
        #expect(windowed?.map(\.turn.id) == ["a"])
    }

    @Test func aTurnTheOverlayRetellsGivesWay() {
        let call: [ContentBlock] = [
            .toolUse(id: "toolu_9", name: "Bash", inputPreview: "{}", status: .unknown, meta: nil),
            .toolResult(id: "toolu_9", outputPreview: "ok", isError: false, agentStats: nil),
        ]
        let read = [turn("u", .user, at: 0), turn("srv-growing", at: 1, call)]
        let overlay = [BackgroundOverlayEntry(turn: turn("bg-1", at: 1, call + [.text("done")]), watermark: 50)]
        #expect(BackgroundOverlays.compose(read, localFrom: nil, overlay: overlay).map(\.id) == ["u", "bg-1"])
    }

    @Test func theOverlayJoinsLocalRoundsInWallClockOrder() {
        let server = [turn("u1", .user, at: 0), turn("a1", at: 1)]
        let local = [turn("u2", .user, at: 10), turn("a2", at: 11)]
        let overlay = [BackgroundOverlayEntry(turn: turn("bg-early", at: 5), watermark: 1),
                       BackgroundOverlayEntry(turn: turn("bg-late", at: 20), watermark: 1)]
        let drawn = BackgroundOverlays.compose(server + local, localFrom: 2, overlay: overlay)
        #expect(drawn.map(\.id) == ["u1", "a1", "bg-early", "u2", "a2", "bg-late"])
        // No local rounds: after everything the server holds.
        #expect(BackgroundOverlays.compose(server, localFrom: nil, overlay: overlay).map(\.id)
                == ["u1", "a1", "bg-early", "bg-late"])
        #expect(BackgroundOverlays.compose(server, localFrom: nil, overlay: []).map(\.id) == ["u1", "a1"])
    }

    // MARK: Launch lifecycle

    @Test func theMarkerReadsAsTheTasksLifecycle() {
        let parsed = BackgroundTaskLifecycle.parse(
            ##"  [[codeg-background-task]]{"task_id":"a1","status":"completed","summary":"Survey done","result":"# Found 3","interim":true}"##)
        #expect(parsed == BackgroundTaskLifecycle(taskId: "a1", status: "completed", summary: "Survey done",
                                                  result: "# Found 3", interim: true))
        #expect(BackgroundTaskLifecycle.parse(#"[[codeg-background-task]]{"task_id":"a2"}"#)?.status == nil)
        #expect(BackgroundTaskLifecycle.parse(#"[[codeg-background-task]]{"status":"x"}"#) == nil, "no task id")
        #expect(BackgroundTaskLifecycle.parse("plain output") == nil)
        // `interim: 1` is not a boolean.
        #expect(BackgroundTaskLifecycle.parse(#"[[codeg-background-task]]{"task_id":"a","interim":1}"#)?.interim == false)
    }

    @Test func aSettleFlipsTheLaunchCardOnly() throws {
        let launch = turn("a", at: 1, [
            .toolUse(id: "toolu_1", name: "Task", inputPreview: "{}", status: .unknown, meta: nil),
            .toolResult(id: "toolu_1", outputPreview: "Async agent launched successfully. agentId: x",
                        isError: false, agentStats: nil),
            .toolUse(id: "toolu_2", name: "Bash", inputPreview: "{}", status: .unknown, meta: nil),
            .toolResult(id: "toolu_2", outputPreview: "Command running in background", isError: false, agentStats: nil),
        ])
        let settled = BackgroundSettled(taskId: "a1", status: "completed", summary: "Survey done",
                                        toolUseId: "toolu_1", result: "Found 3")
        let flipped = try #require(BackgroundTaskLifecycle.settle([launch], settled))
        guard case .toolResult(_, let output, _, _, _) = flipped[0].blocks[1] else { Issue.record("no result"); return }
        #expect(BackgroundTaskLifecycle.parse(output) == BackgroundTaskLifecycle(
            taskId: "a1", status: "completed", summary: "Survey done", result: "Found 3", interim: false))
        #expect(flipped[0].blocks[3] == launch.blocks[3])
        // Settled again with the same: nothing to change.
        #expect(BackgroundTaskLifecycle.settle(flipped, settled) == nil)
        // A shell's notification names its command call: that card stays.
        let shell = BackgroundSettled(taskId: "b1", status: "completed", toolUseId: "toolu_2")
        #expect(BackgroundTaskLifecycle.settle([launch], shell) == nil)
        #expect(BackgroundTaskLifecycle.settle([launch], BackgroundSettled(taskId: "a1", status: "completed")) == nil)
    }

    // MARK: Fork points

    /// An overlay turn's id is the watcher's, not the backend's parse's: no
    /// "Fork from here" may name it (Codex review). At the tail a fork names
    /// nothing anyway, so it stays on offer there.
    @MainActor @Test func noForkPointNamesATurnHeldAheadOfTheServer() throws {
        let server = [turn("u1", .user, at: 0, [.text("Audit it")]), turn("a1", at: 1, [.text("Started.")])]
        let local = [turn("u2", .user, at: 10, [.text("Next")]), turn("a2", at: 11, [.text("Done next.")])]
        let early = [BackgroundOverlayEntry(turn: turn("bg-9-0", at: 5, [.text("The audit finished.")]), watermark: 9)]
        func forkPoints(_ overlay: [BackgroundOverlayEntry], _ turns: [MessageTurn], localFrom: Int?) -> [ReplyForkPoint] {
            let drawn = BackgroundOverlays.compose(turns, localFrom: localFrom, overlay: overlay)
            return TranscriptTimeline.buildPersistedTier(
                turns: drawn, pending: [], agent: .claudeCode, suppressInFlight: false, forkPoints: true,
                heldAhead: Set(overlay.map(\.turn.id))).nodes.compactMap(\.forkPoint)
        }
        // Joined onto a1 (consecutive assistant turns are one reply), it is
        // that reply's last turn — and a folded round follows it.
        let middle = forkPoints(early, server + local, localFrom: 2)
        #expect(middle.map(\.turnID) == ["bg-9-0", "a2"])
        #expect(middle[0].request(agent: .claudeCode) == nil, "never a point the server can't resolve")
        #expect(middle[1].request(agent: .claudeCode) == ReplyForkPoint.Request(forkFromTurnId: "a2"))
        // At the tail: offered, naming nothing.
        let tail = forkPoints([BackgroundOverlayEntry(turn: turn("bg-9-1", at: 20, [.text("Later.")]), watermark: 9)],
                              server, localFrom: nil)
        #expect(tail.map(\.turnID) == ["bg-9-1"])
        #expect(tail[0].request(agent: .claudeCode) == ReplyForkPoint.Request(forkFromTurnId: nil))
    }
}
