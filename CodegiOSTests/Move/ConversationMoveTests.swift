import Foundation
import Testing
@testable import Codeg

/// "Move to…" (web `move-conversation-dialog` / `move-to-folder-menu`, Android
/// `CodegJsonTest` move cases): what may move, where to, and what the server's
/// camelCase answer says.
@Suite struct ConversationMoveTests {
    private typealias F = TagFixtures

    @Test func aMoveAnswersInCamelCase() throws {
        let result = try CodegJSON.decoder.decode(MoveConversationsResult.self, from: Data("""
        {"moved":[1],"skipped":[{"conversationId":2,"reason":"busy"},{"conversationId":3,"reason":"task_owned"}]}
        """.utf8))
        #expect(result.moved == [1])
        #expect(result.skipped == [
            MoveConversationSkip(conversationId: 2, reason: .busy),
            MoveConversationSkip(conversationId: 3, reason: .taskOwned),
        ])
    }

    @Test func everySkipReasonReadsAndAnUnknownOneIsKept() throws {
        func reason(_ raw: String) throws -> MoveSkipReason {
            try CodegJSON.decoder.decode(MoveSkipReason.self, from: Data("\"\(raw)\"".utf8))
        }
        #expect(try reason("not_found") == .notFound)
        #expect(try reason("not_movable") == .notMovable)
        #expect(try reason("already_there") == .alreadyThere)
        #expect(try reason("task_owned") == .taskOwned)
        #expect(try reason("busy") == .busy)
        #expect(try reason("conflict") == .conflict)
        #expect(try reason("target_unavailable") == .targetUnavailable)
        #expect(try reason("archived") == .other("archived"))
    }

    @Test func anEmptyAnswerIsNothingMovedRatherThanAFailure() throws {
        let result = try CodegJSON.decoder.decode(MoveConversationsResult.self, from: Data("{}".utf8))
        #expect(result.moved.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test func theRequestIsCamelCase() throws {
        let data = try CodegJSON.encoder.encode(MoveConversationsBody(conversationIds: [3], targetFolderId: 7))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["conversationIds"] as? [Int] == [3])
        #expect(json["targetFolderId"] as? Int == 7)
    }

    @Test func aRootRegularOrChatConversationMovesAndNothingElseDoes() {
        #expect(F.summary(1, kind: "regular").isMovable)
        #expect(F.summary(1, kind: "chat").isMovable)
        #expect(!F.summary(1, kind: "loop").isMovable)
        #expect(!F.summary(2, parent: 1, kind: "delegate").isMovable)
        #expect(!F.summary(2, parent: 1, kind: "regular").isMovable, "a sub-session moves with its parent")
        // A server that sends no kind: a root row moves.
        #expect(F.summary(1).isMovable)
        #expect(F.summary(1, kind: "something_new").kind == .other)
        #expect(!F.summary(1, kind: "something_new").isMovable)
    }

    @Test func targetsAreTheOtherOpenFoldersWorktreesIncludedChatsNot() {
        let open = [F.folder(1), F.folder(2), F.folder(3, parent: 1), F.folder(4, kind: .chat)]
        #expect(ConversationMove.targets(open: open, currentFolderID: 1).map(\.id) == [2, 3])
        #expect(ConversationMove.targets(open: open, currentFolderID: 4).map(\.id) == [1, 2, 3])
        #expect(ConversationMove.targets(open: [F.folder(1)], currentFolderID: 1).isEmpty)
    }

    @Test func aWorktreeIsNamedByItsRepoAndBranch() {
        let all = [F.folder(1, name: "repo"), F.folder(3, parent: 1, name: "wt-8f2c", branch: "feature/x")]
        #expect(ConversationMove.label(for: all[1], in: all) == "repo · feature/x")
        #expect(ConversationMove.label(for: all[0], in: all) == "repo")
        // Its root unknown: its own name, still with the branch.
        #expect(ConversationMove.label(for: all[1], in: [all[1]]) == "wt-8f2c · feature/x")
    }

    @Test func theOutcomeIsReadForTheConversationAskedAbout() {
        let result = MoveConversationsResult(moved: [1], skipped: [MoveConversationSkip(conversationId: 2, reason: .busy)])
        #expect(ConversationMove.outcome(of: result, for: 1) == .moved)
        #expect(ConversationMove.outcome(of: result, for: 2) == .skipped(.busy))
        #expect(ConversationMove.outcome(of: result, for: 3) == .unknown)
        #expect(ConversationMove.message(for: result, conversationID: 1, folderName: "Elsewhere")?.contains("Elsewhere") == true)
        #expect(ConversationMove.message(for: result, conversationID: 3, folderName: "Elsewhere") == nil)
    }
}
