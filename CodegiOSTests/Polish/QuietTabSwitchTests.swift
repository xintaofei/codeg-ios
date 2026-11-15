import Foundation
import Observation
import Testing
@testable import Codeg

/// A refetch that brings back what is on screen tells no reader: an equal
/// assignment notifies no one, so what matters is what is written apart —
/// the badge's count — and what is mutated in place — the picks.
@MainActor
struct QuietRefetchTests {
    private typealias F = TagFixtures

    /// Whether reading `read` registered a change during `body`.
    private func changes(_ read: @escaping () -> Void, during body: () -> Void) -> Bool {
        var changed = false
        withObservationTracking(read) { changed = true }
        body()
        return changed
    }

    @Test func theBadgeRedrawsOnlyWhenTheRunningCountChanges() {
        let activity = ActivityModel()
        let rows = [F.summary(1, status: "in_progress"), F.summary(2), F.summary(3, status: "pending_review")]
        activity.adopt(folders: [F.folder(1)], openFolders: [F.folder(1)], conversations: rows)
        #expect(activity.runningCount == activity.running.count)

        // A pulse that moves the list on (statuses traded between rows, a
        // running row's time) without changing how many run.
        let traded = [F.summary(1, status: "in_progress"), F.summary(2, status: "pending_review"), F.summary(3)]
        #expect(!changes({ _ = activity.runningCount }) {
            activity.adopt(folders: nil, openFolders: nil, conversations: traded)
        })
        #expect(activity.conversations == traded)
        #expect(activity.runningCount == activity.running.count)

        #expect(changes({ _ = activity.runningCount }) {
            activity.adopt(folders: nil, openFolders: nil, conversations: [F.summary(1)])
        })
        #expect(activity.runningCount == 0)
    }

    @Test func aRefetchThatPrunesNothingLeavesThePicksAlone() {
        let model = SessionListViewModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        let rows = [F.summary(1), F.summary(2)]
        model.adopt(folders: [F.folder(1)], openFolders: [F.folder(1)], conversations: rows)
        #expect(!changes({ _ = model.selection }) {
            model.adopt(folders: [F.folder(1)], openFolders: [F.folder(1)], conversations: rows)
        })
    }
}
