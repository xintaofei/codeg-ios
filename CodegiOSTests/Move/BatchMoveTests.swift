import Foundation
import Testing
@testable import Codeg

/// Moving several conversations at once from the Chats list's selection mode
/// (web Manage conversations + `MoveConversationDialog`): what may be picked,
/// how picks survive the list changing under them, where they may go, and how
/// a partly successful move is told and left.
@Suite struct BatchMoveTests {
    private typealias F = TagFixtures

    // MARK: - Picking

    @Test func onlyAConversationThatMayMoveCanBePicked() {
        let rows = [F.summary(1), F.summary(2, parent: 1), F.summary(3, kind: "loop"), F.summary(4, kind: "chat")]
        var selection = ConversationSelection()
        selection.set([1, 2, 3, 4, 99], among: rows)
        #expect(selection.ids == [1, 4], "a sub-session, a loop and an unknown id are not picks")

        selection.toggle(rows[1])
        #expect(!selection.contains(2))
        selection.toggle(rows[0])
        #expect(!selection.contains(1))
        selection.toggle(rows[0])
        #expect(selection.contains(1))
    }

    @Test func selectAllCoversTheRowsOnScreenAndLeavesHiddenPicksAlone() {
        let all = [F.summary(1), F.summary(2), F.summary(3), F.summary(4, parent: 1)]
        var selection = ConversationSelection()
        selection.set([3], among: all)
        // A filter shows 1, 2 and the sub-session.
        let visible = [all[0], all[1], all[3]]
        #expect(!selection.coversAll(visible))

        selection.toggleAll(visible)
        #expect(selection.ids == [1, 2, 3], "the hidden pick stays; the sub-session is no pick")
        #expect(selection.coversAll(visible))

        selection.toggleAll(visible)
        #expect(selection.ids == [3], "Deselect All lets go of what shows only")
    }

    @Test func selectAllOverNothingPickableDoesNothing() {
        var selection = ConversationSelection()
        let visible = [F.summary(2, parent: 1)]
        #expect(!selection.coversAll(visible))
        selection.toggleAll(visible)
        #expect(selection.isEmpty)
        #expect(!selection.coversAll([]))
    }

    @Test func aRefetchDropsPicksWhoseRowsAreGoneOrNoLongerMovable() {
        var selection = ConversationSelection()
        selection.set([1, 2, 3], among: [F.summary(1), F.summary(2), F.summary(3)])
        selection.prune(to: [F.summary(1), F.summary(3, parent: 9)])
        #expect(selection.ids == [1])
    }

    @Test func thePicksAreTakenInListOrder() {
        let rows = [F.summary(5), F.summary(2), F.summary(9)]
        var selection = ConversationSelection()
        selection.set([9, 5], among: rows)
        #expect(selection.picked(from: rows).map(\.id) == [5, 9])
    }

    @Test func aMoveLetsGoOfWhatMovedAndKeepsWhatWasLeftBehind() {
        var selection = ConversationSelection()
        selection.set([1, 2, 3], among: [F.summary(1), F.summary(2), F.summary(3)])
        selection.settle(MoveConversationsResult(moved: [1, 3], skipped: [MoveConversationSkip(conversationId: 2, reason: .busy)]))
        #expect(selection.ids == [2])
    }

    // MARK: - Where to

    @Test func picksSharingAFolderLeaveItOutOfTheTargetsAndMixedOnesLeaveNoneOut() {
        let open = [F.folder(1), F.folder(2), F.folder(3, kind: .chat)]
        let same = [F.summary(1, folder: 1), F.summary(2, folder: 1)]
        let mixed = [F.summary(1, folder: 1), F.summary(2, folder: 2)]
        #expect(ConversationMove.sharedFolderID(same) == 1)
        #expect(ConversationMove.sharedFolderID(mixed) == nil)
        #expect(ConversationMove.sharedFolderID([]) == nil)
        #expect(ConversationMove.targets(open: open, currentFolderID: ConversationMove.sharedFolderID(same)).map(\.id) == [2])
        #expect(ConversationMove.targets(open: open, currentFolderID: ConversationMove.sharedFolderID(mixed)).map(\.id) == [1, 2],
                "the server skips the ones already there")
    }

    // MARK: - Outcome

    @Test func theOutcomeSplitsTheAskedIntoMovedAndLeftWithEachReasonOnce() {
        let result = MoveConversationsResult(moved: [3, 1], skipped: [
            MoveConversationSkip(conversationId: 2, reason: .busy),
            MoveConversationSkip(conversationId: 4, reason: .busy),
            MoveConversationSkip(conversationId: 5, reason: .taskOwned),
        ])
        let outcome = ConversationMove.batchOutcome(of: result, requested: [1, 2, 3, 4, 5, 6, 1])
        #expect(outcome.moved == [1, 3], "in the order asked, once each")
        #expect(outcome.notMoved == [2, 4, 5, 6], "named in neither list counts as left behind")
        #expect(outcome.reasons == [MoveSkipReason.busy.message, MoveSkipReason.taskOwned.message])
        #expect(!outcome.movedAll)
        #expect(ConversationMove.batchOutcome(of: MoveConversationsResult(moved: [1, 2], skipped: []),
                                              requested: [1, 2]).movedAll)
    }

    @Test func reasonsThatReadTheSameAreSaidOnce() {
        let result = MoveConversationsResult(moved: [], skipped: [
            MoveConversationSkip(conversationId: 1, reason: .other("archived")),
            MoveConversationSkip(conversationId: 2, reason: .other("frozen")),
        ])
        #expect(ConversationMove.batchOutcome(of: result, requested: [1, 2]).reasons.count == 1)
    }

    @Test func everyOneMovedIsOneLine() throws {
        let result = MoveConversationsResult(moved: [1, 2, 3], skipped: [])
        let message = try #require(ConversationMove.batchMessage(for: result, requested: [1, 2, 3], folderName: "Elsewhere"))
        #expect(!message.contains("\n"))
        #expect(message.contains("Elsewhere"))
        #expect(message.contains("3"))
    }

    @Test func aPartialMoveSaysHowManyMovedThenHowManyDidNotAndWhy() throws {
        let result = MoveConversationsResult(moved: [1, 2], skipped: [
            MoveConversationSkip(conversationId: 3, reason: .busy),
            MoveConversationSkip(conversationId: 4, reason: .alreadyThere),
        ])
        let message = try #require(ConversationMove.batchMessage(for: result, requested: [1, 2, 3, 4], folderName: "Elsewhere"))
        let lines = message.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains("Elsewhere"))
        #expect(lines[0].contains("2"))
        #expect(lines[1].contains("2"))
        #expect(lines[1].contains(MoveSkipReason.busy.message))
        #expect(lines[1].contains(MoveSkipReason.alreadyThere.message))
    }

    @Test func nothingMovedIsOnlyTheLeftBehindLine() throws {
        let result = MoveConversationsResult(moved: [], skipped: [
            MoveConversationSkip(conversationId: 1, reason: .busy),
            MoveConversationSkip(conversationId: 2, reason: .busy),
        ])
        let message = try #require(ConversationMove.batchMessage(for: result, requested: [1, 2], folderName: "Elsewhere"))
        #expect(!message.contains("\n"))
        #expect(!message.contains("Elsewhere"))
        #expect(message.contains(MoveSkipReason.busy.message))
    }

    @Test func aMoveOfOneReadsAsTheSingleMove() {
        let moved = MoveConversationsResult(moved: [1], skipped: [])
        #expect(ConversationMove.batchMessage(for: moved, requested: [1], folderName: "Elsewhere")
                == ConversationMove.message(for: moved, conversationID: 1, folderName: "Elsewhere"))
        let skipped = MoveConversationsResult(moved: [], skipped: [MoveConversationSkip(conversationId: 1, reason: .busy)])
        #expect(ConversationMove.batchMessage(for: skipped, requested: [1], folderName: "Elsewhere")
                == ConversationMove.message(for: skipped, conversationID: 1, folderName: "Elsewhere"))
        #expect(ConversationMove.batchMessage(for: moved, requested: [], folderName: "Elsewhere") == nil)
    }

    @Test func aLongerNoticeStaysUpLonger() {
        #expect(TransientNotice.duration(for: "Moved to Elsewhere") == .seconds(4))
        #expect(TransientNotice.duration(for: "Moved 2 conversations\n1 was not moved") == .seconds(7))
    }

    // MARK: - The list's selection mode

    @MainActor
    @Test func theListPicksOnlyMovableRowsAndAPickGoneFromARefetchIsDropped() {
        let model = SessionListViewModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        let folders = [F.folder(1), F.folder(2)]
        model.adopt(folders: folders, openFolders: folders,
                    conversations: [F.summary(1, folder: 1), F.summary(2, folder: 1), F.summary(3, folder: 2, parent: 1)])
        #expect(model.canSelect)

        model.beginSelecting()
        #expect(model.isSelecting)
        model.setSelection([1, 2, 3])
        #expect(model.selection.ids == [1, 2])
        #expect(model.selectedConversations.map(\.id) == [1, 2])

        // Conversation 2 was deleted elsewhere.
        model.adopt(folders: nil, openFolders: nil, conversations: [F.summary(1, folder: 1), F.summary(3, folder: 2, parent: 1)])
        #expect(model.selection.ids == [1])

        model.endSelecting()
        #expect(!model.isSelecting)
        #expect(model.selection.isEmpty)
    }

    @MainActor
    @Test func selectAllInTheListCoversWhatTheFiltersLeaveShowing() {
        let model = SessionListViewModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        let folders = [F.folder(1)]
        model.adopt(folders: folders, openFolders: folders,
                    conversations: [F.summary(1, tags: [7]), F.summary(2), F.summary(3, tags: [7])],
                    tags: [F.tag(7)])
        model.setTagFilter(TagFilter(tagIDs: [7]))
        model.beginSelecting()
        let visible = model.folderGroups(searchText: "").flatMap(\.conversations)
        model.toggleSelectAll(visible)
        #expect(model.selection.ids == [1, 3])
        model.setTagFilter(.none)
    }

    @MainActor
    @Test func nothingMovableMeansNoSelectionMode() {
        let model = SessionListViewModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        model.adopt(folders: [], openFolders: [], conversations: [F.summary(2, parent: 1)])
        #expect(!model.canSelect)
    }
}
