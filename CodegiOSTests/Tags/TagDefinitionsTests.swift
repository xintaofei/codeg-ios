import Foundation
import Testing
@testable import Codeg

/// The chips the session header, Activity and Search draw: resolved by the
/// same rule as a Chats row, against definitions those surfaces read for
/// themselves, and patched by the confirmed tag writes of their own server.
@Suite struct TagDefinitionsTests {
    private typealias F = TagFixtures

    @Test func aRowResolvesItsKnownTagsInOrderAndItsBranchWhenTheBranchTagIsOn() {
        let byID = [7: F.tag(7, order: 2), 8: F.tag(8, order: 1), 9: F.tag(9, folder: 1)]
        let on = BranchTagSetting(enabled: true, color: "#0969da")
        let row = RowTags.resolve(F.summary(1, tags: [9, 7, 8, 42], branch: "main"), tagsByID: byID, branchTag: on)
        #expect(row.tags.map(\.id) == [8, 7, 9], "global first, each scope in its order; an unknown id dropped")
        #expect(row.branch == "main")
        #expect(row.branchColor == "#0969da")

        let off = RowTags.resolve(F.summary(1, tags: [7], branch: "main"), tagsByID: byID, branchTag: BranchTagSetting())
        #expect(off.branch == nil)
        #expect(off.tags.map(\.id) == [7])
    }

    @Test func aSubSessionOrAnUntaggedRowDrawsNothing() {
        let byID = [7: F.tag(7)]
        let on = BranchTagSetting(enabled: true, color: "#6e7781")
        #expect(RowTags.resolve(F.summary(2, tags: [7], branch: "main", parent: 1), tagsByID: byID, branchTag: on) == .none)
        #expect(RowTags.resolve(F.summary(1), tagsByID: byID, branchTag: on) == .none)
        #expect(RowTags.resolve(F.summary(1, tags: [42]), tagsByID: byID, branchTag: BranchTagSetting()) == .none,
                "only deleted tags: nothing to draw")
    }

    @MainActor
    @Test func definitionsResolveRowsAndAFailedHalfKeepsWhatWasThere() {
        let model = TagDefinitionsModel()
        let conversation = F.summary(1, tags: [7], branch: "main")
        #expect(model.rowTags(for: conversation) == .none)

        model.adopt(tags: [F.tag(7, name: "bug")], branchTag: BranchTagSetting(enabled: true, color: "#cf222e"))
        #expect(model.rowTags(for: conversation).tags.map(\.name) == ["bug"])
        #expect(model.rowTags(for: conversation).branch == "main")

        // The tag read failed this time: the chips stay; the branch setting moves on.
        model.adopt(tags: nil, branchTag: BranchTagSetting(enabled: false, color: "#cf222e"))
        #expect(model.rowTags(for: conversation).tags.map(\.name) == ["bug"])
        #expect(model.rowTags(for: conversation).branch == nil)

        model.reset()
        #expect(model.rowTags(for: conversation) == .none)
        #expect(model.endpoint == nil)
    }

    @Test func aConfirmedWritePatchesOnlyItsOwnServersRow() {
        var rows = [F.summary(1, tags: [1]), F.summary(2)]
        // `#expect` can't take a mutating call: each result is read first.
        let elsewhere = rows.applyTagChange(ConversationTagsChange(endpoint: "http://elsewhere", conversationID: 1, tagIDs: [5]),
                                            endpoint: "http://here")
        #expect(!elsewhere)
        #expect(rows[0].tagIds == [1])
        let absent = rows.applyTagChange(ConversationTagsChange(endpoint: "http://here", conversationID: 3, tagIDs: [5]),
                                         endpoint: "http://here")
        #expect(!absent, "not in this list")
        let patched = rows.applyTagChange(ConversationTagsChange(endpoint: "http://here", conversationID: 2, tagIDs: [4, 5]),
                                          endpoint: "http://here")
        #expect(patched)
        #expect(rows[1].tagIds == [4, 5])
        let unchanged = rows.applyTagChange(ConversationTagsChange(endpoint: "http://here", conversationID: 2, tagIDs: [4, 5]),
                                            endpoint: "http://here")
        #expect(!unchanged, "unchanged: nothing to redraw")
        // A list from no server patches nothing.
        let noServer = rows.applyTagChange(ConversationTagsChange(endpoint: "http://here", conversationID: 1, tagIDs: []),
                                           endpoint: nil)
        #expect(!noServer)
    }

    @MainActor
    @Test func activityPatchesNothingBeforeItHasLoadedFromAServer() {
        let activity = ActivityModel()
        activity.applyTagChange(ConversationTagsChange(endpoint: "http://here", conversationID: 1, tagIDs: [5]))
        #expect(activity.conversations.isEmpty)
    }
}
