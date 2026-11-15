import Foundation
import Testing
@testable import Codeg

/// A send's reply only takes what the server streams once it has started that
/// send's turn. Before then the stream is the turn before it — Grok's own turn,
/// which the server closes with `turn_complete(cancelled)` just ahead of a
/// prompt queued behind it.
@MainActor
struct OwnTurnStartTests {
    private func snapshot(_ json: String) throws -> LiveSessionSnapshot {
        try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(json.utf8))
    }

    @Test func theTurnBeforesContentAndEndAreNotThisReplys() {
        let before: [AcpEvent] = [
            .contentDelta(text: "tail", parentToolUseId: nil),
            .thinking(text: "hm", parentToolUseId: nil),
            .turnComplete(stopReason: "cancelled"),
            .planUpdate(entries: []),
            .error(message: "boom", code: nil, details: nil),
            .error(message: "verdict", code: "turn_failed_empty", details: nil),
        ]
        for event in before {
            #expect(SessionDetailViewModel.belongsToTheTurnBefore(event), "\(event)")
        }
    }

    @Test func connectionEventsStillLand() {
        let connection: [AcpEvent] = [
            .statusChanged(status: .prompting),
            .statusChanged(status: .error),
            .error(message: "dropped image", code: "image_dropped", details: nil),
            .forkSupported(supported: true),
        ]
        for event in connection {
            #expect(!SessionDetailViewModel.belongsToTheTurnBefore(event), "\(event)")
        }
    }

    @Test func aSnapshotRunningThisPromptStartsItsTurn() throws {
        let snap = try snapshot(#"""
        {"status":"prompting","pending_user_message":{"message_id":"m-1","blocks":[]}}
        """#)
        #expect(snap.pendingUserMessageId == "m-1")
        #expect(snap.startsTurn(forPrompt: "m-1"))
        #expect(!snap.startsTurn(forPrompt: "m-2"))
    }

    @Test func anAgentsOwnTurnStartsNoPromptsTurn() throws {
        // Grok prompting on its own: no user message behind it.
        let snap = try snapshot(#"{"status":"prompting"}"#)
        #expect(snap.pendingUserMessageId == nil)
        #expect(!snap.startsTurn(forPrompt: "m-1"))
    }

    @Test func anIdleSnapshotStartsNothing() throws {
        let snap = try snapshot(#"""
        {"status":"connected","pending_user_message":{"message_id":"m-1","blocks":[]}}
        """#)
        #expect(!snap.startsTurn(forPrompt: "m-1"))
    }
}
