import Foundation
import Testing
@testable import Codeg

/// The pure tag rules (web `lib/conversation-tags.test.ts`, Android
/// `ConversationTagsTest`) and the wire shapes they read.
@Suite struct ConversationTagsTests {
    private typealias F = TagFixtures

    // MARK: - Wire

    @Test func aTagDecodesItsScopeAndOrderFromSnakeCase() throws {
        let tags = try CodegJSON.decoder.decode([ConversationTag].self, from: Data("""
        [{"id":1,"folder_id":null,"name":"bug","color":"#cf222e","sort_order":2},
         {"id":2,"folder_id":7,"name":"review","color":"#0969da","sort_order":1}]
        """.utf8))
        #expect(tags[0] == ConversationTag(id: 1, folderId: nil, name: "bug", color: "#cf222e", sortOrder: 2))
        #expect(tags[1].folderId == 7)
        #expect(tags[1].sortOrder == 1)
    }

    @Test func theBranchTagSettingDecodes() throws {
        let setting = try CodegJSON.decoder.decode(BranchTagSetting.self, from: Data(##"{"enabled":true,"color":"#6e7781"}"##.utf8))
        #expect(setting == BranchTagSetting(enabled: true, color: "#6e7781"))
        #expect(BranchTagSetting().color == BranchTagSetting.defaultColor)
    }

    @Test func aSummaryReadsItsTagsAndParentAndAbsentTagsAsNone() {
        let tagged = F.summary(1, tags: [2, 5])
        #expect(tagged.tagIds == [2, 5])
        #expect(tagged.canCarryTags)
        let child = F.summary(2, parent: 1)
        #expect(child.tagIds.isEmpty)
        #expect(child.parentId == 1)
        #expect(!child.canCarryTags)
    }

    @Test func aSummaryCanBePatchedWithItsNewTags() {
        var summary = F.summary(1, tags: [3])
        summary.tagIds = [3, 4]
        #expect(summary.tagIds == [3, 4])
        summary.tagIds = []
        #expect(summary.tagIds.isEmpty)
    }

    @Test func requestBodiesAreCamelCaseAndLeaveOutWhatIsNil() throws {
        func json<Body: Encodable>(_ body: Body) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: CodegJSON.encoder.encode(body)) as! [String: Any]
        }
        let global = try json(CreateConversationTagBody(folderId: nil, name: "bug", color: "#cf222e"))
        #expect(!global.keys.contains("folderId"), "omitted = a global tag")
        #expect(global["name"] as? String == "bug")
        let scoped = try json(CreateConversationTagBody(folderId: 3, name: "x", color: "#cf222e"))
        #expect(scoped["folderId"] as? Int == 3)
        let rename = try json(UpdateConversationTagBody(tagId: 4, name: "new", color: nil))
        #expect(rename["tagId"] as? Int == 4)
        #expect(!rename.keys.contains("color"), "omitted = left as it is")
        let delta = try json(UpdateConversationTagsBody(conversationId: 9, add: [1], remove: [2]))
        #expect(delta["conversationId"] as? Int == 9)
        #expect(delta["add"] as? [Int] == [1])
        #expect(delta["remove"] as? [Int] == [2])
        #expect(try json(ReorderConversationTagsBody(tagIds: [3, 1]))["tagIds"] as? [Int] == [3, 1])
        #expect(try json(ConversationTagIdBody(tagId: 5))["tagId"] as? Int == 5)
        let branch = try json(UpdateBranchTagBody(enabled: true, color: "#6e7781"))
        #expect(branch["enabled"] as? Bool == true)
    }

    // MARK: - Scope and order

    @Test func aWorktreeIsOfferedItsReposTagsAndAChatNoneOfItsOwn() {
        #expect(ConversationTags.scopeFolderID(F.folder(1)) == 1)
        #expect(ConversationTags.scopeFolderID(F.folder(2, parent: 1)) == 1)
        #expect(ConversationTags.scopeFolderID(F.folder(3, kind: .chat)) == nil)
        #expect(ConversationTags.scopeFolderID(nil) == nil)
        #expect(ConversationTags.fits(F.tag(1), scope: nil))
        #expect(ConversationTags.fits(F.tag(2, folder: 1), scope: 1))
        #expect(!ConversationTags.fits(F.tag(3, folder: 2), scope: 1))
    }

    @Test func tagsReadGlobalFirstThenByFolderInTheirOrderAndUnknownIdsDrop() {
        let byID = Dictionary(uniqueKeysWithValues: [
            F.tag(5, folder: 2, order: 1), F.tag(4, order: 2), F.tag(3, order: 1), F.tag(2, folder: 1, order: 1),
        ].map { ($0.id, $0) })
        #expect(ConversationTags.resolve([5, 2, 4, 3, 99], in: byID).map(\.id) == [3, 4, 2, 5])
        #expect(ConversationTags.resolve([], in: byID).isEmpty)
    }

    @Test func aNewTagTakesTheFirstStrongColourItsNeighboursLeaveFree() {
        #expect(ConversationTags.nextColor(neighbours: []) == "#cf222e")
        #expect(ConversationTags.nextColor(neighbours: [F.tag(1, color: "#CF222E")]) == "#bc4c00")
        let all = ConversationTags.colorPresets.prefix(9).enumerated().map { F.tag($0.offset, color: $0.element) }
        #expect(ConversationTags.nextColor(neighbours: all) == ConversationTags.colorPresets[0])
    }

    @Test func thePaletteIsTheWebsPresetList() {
        #expect(ConversationTags.colorPresets.count == 18)
        #expect(ConversationTags.colorPresets.first == "#cf222e")
        #expect(ConversationTags.colorPresets.last == "#e2e8f0")
    }

    @Test func coloursNormalizeTheServersWay() {
        #expect(ConversationTags.normalizeColor(" #ABC ") == "#aabbcc")
        #expect(ConversationTags.normalizeColor("#A1B2C3") == "#a1b2c3")
        #expect(ConversationTags.normalizeColor("red") == nil)
        #expect(ConversationTags.normalizeColor("#abcd") == nil)
        #expect(ConversationTags.normalizeColor("abc") == nil)
        #expect(ConversationTags.normalizeColor("#ｆｆｆ") == nil, "full-width digits are not hex to the server")
    }

    @Test func namesMatchCaseInsensitivelyWithinAScopeOnly() {
        let tags = [F.tag(1, name: "Bug"), F.tag(2, folder: 1, name: "review")]
        #expect(ConversationTags.find(named: " bug ", scope: nil, in: tags)?.id == 1)
        #expect(ConversationTags.find(named: "bug", scope: 1, in: tags) == nil)
        #expect(ConversationTags.find(named: "REVIEW", scope: 1, in: tags)?.id == 2)
        #expect(ConversationTags.find(named: "  ", scope: nil, in: tags) == nil)
    }

    @Test func aNameIsCappedAtSixtyFourScalarsAfterTrimming() {
        #expect(ConversationTags.cappedName("  bug  ") == "bug")
        let long = String(repeating: "é", count: 70)
        #expect(ConversationTags.cappedName(long).unicodeScalars.count == 64)
    }

    @Test func aSubSessionShowsNoBranchChip() {
        #expect(ConversationTags.branchChip(for: F.summary(1, branch: "main", parent: 9), enabled: true) == nil)
        #expect(ConversationTags.branchChip(for: F.summary(1, branch: " main "), enabled: true) == "main")
        #expect(ConversationTags.branchChip(for: F.summary(1, branch: "  "), enabled: true) == nil)
        #expect(ConversationTags.branchChip(for: F.summary(1, branch: "main"), enabled: false) == nil)
    }

    // MARK: - Filter

    @Test func aFilterMatchesAnyOrAllTogglesInOrderAndForgetsDeletedTags() {
        let c = F.summary(1, tags: [1, 2])
        #expect(TagFilter(tagIDs: [1, 3]).matches(c))
        #expect(!TagFilter(tagIDs: [1, 3], mode: .matchAll).matches(c))
        #expect(TagFilter(tagIDs: [2, 1], mode: .matchAll).matches(c))
        #expect(!TagFilter(tagIDs: [1]).matches(F.summary(2)))
        #expect(TagFilter.none.matches(F.summary(2)))
        #expect(TagFilter(tagIDs: [3]).toggling(1).tagIDs == [3, 1])
        #expect(TagFilter(tagIDs: [3, 1]).toggling(1).tagIDs == [3])
        let kept = TagFilter(tagIDs: [1, 2], mode: .matchAll)
        #expect(kept.pruned(known: [1, 2, 3]) == kept)
        #expect(kept.pruned(known: [2]) == TagFilter(tagIDs: [2], mode: .matchAll))
    }

    @Test func aFilterIsSavedPerServerAndAnInactiveOneIsNotKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "tag-filter-\(UUID().uuidString)"))
        let filter = TagFilter(tagIDs: [4, 2], mode: .matchAll)
        TagFilterStore.save(filter, server: "a", defaults: defaults)
        #expect(TagFilterStore.load(server: "a", defaults: defaults) == filter)
        #expect(TagFilterStore.load(server: "b", defaults: defaults) == TagFilter.none)
        TagFilterStore.save(.none, server: "a", defaults: defaults)
        #expect(TagFilterStore.load(server: "a", defaults: defaults) == TagFilter.none)
    }

    // MARK: - Chip colours

    @Test func chipsStayReadableInBothThemes() throws {
        // Light: the colour fills; white text on a dark colour, black on a pale one.
        let red = try #require(TagSwatch.make("#cf222e", dark: false))
        #expect(red.background == 0xFFCF_222E)
        #expect(red.foreground == 0xFFFF_FFFF)
        #expect(try #require(TagSwatch.make("#fde68a", dark: false)).foreground == 0xFF00_0000)
        // Only the near-white get a rim in light.
        #expect(red.border >> 24 == 0)
        #expect(try #require(TagSwatch.make("#ffffff", dark: false)).border >> 24 > 0)
        // Dark: the colour at 18% fills; the text is the colour lifted, opaque.
        let blue = try #require(TagSwatch.make("#0969da", dark: true))
        #expect(blue.background >> 24 == 0x2E)
        #expect(blue.background & 0x00FF_FFFF == 0x0969DA)
        #expect(blue.foreground >> 24 == 0xFF)
        #expect(blue.border >> 24 == 0x4D, "30% rim")
        #expect(TagSwatch.make("nope", dark: true) == nil)
        #expect(TagSwatch.make("#abc", dark: true) == nil, "only #rrggbb is drawn in colour")
    }

    @Test func aDarkThemeTextIsLighterThanItsColour() throws {
        // Navy is unreadable as-is on a dark surface; the text is lifted.
        let navy = try #require(TagSwatch.make("#1f2a5a", dark: true))
        let channelSum = { (argb: UInt32) in ((argb >> 16) & 0xff) + ((argb >> 8) & 0xff) + (argb & 0xff) }
        #expect(channelSum(navy.foreground) > channelSum(0x1F2A5A))
    }

    // MARK: - List

    @MainActor
    @Test func aFilteredListDropsTheFoldersItEmptiesAndResolvesEachRowsChips() {
        let model = SessionListViewModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        let folders = [F.folder(1), F.folder(2)]
        model.adopt(
            folders: folders, openFolders: folders,
            conversations: [F.summary(1, folder: 1, tags: [7], branch: "main"), F.summary(2, folder: 2),
                            F.summary(3, folder: 2, tags: [8], pinned: true)],
            tags: [F.tag(7), F.tag(8, folder: 2)],
            branchTag: BranchTagSetting(enabled: true, color: "#6e7781")
        )
        let row = model.rowTags(for: model.conversations[0])
        #expect(row.tags.map(\.id) == [7])
        #expect(row.branch == "main")
        #expect(model.rowTags(for: model.conversations[1]) == RowTags.none)

        model.setTagFilter(TagFilter(tagIDs: [7]))
        #expect(model.folderGroups(searchText: "").map(\.folder.id) == [1])
        #expect(model.pinned(searchText: "").isEmpty)
        #expect(!model.isFilteredEmpty)

        model.setTagFilter(TagFilter(tagIDs: [7, 8]))
        #expect(model.folderGroups(searchText: "").map(\.folder.id) == [1])
        #expect(model.pinned(searchText: "").map(\.id) == [3])

        model.setTagFilter(TagFilter(tagIDs: [7, 8], mode: .matchAll))
        #expect(model.isFilteredEmpty)
        #expect(model.folderGroups(searchText: "").isEmpty)
    }

    @MainActor
    @Test func aSavedFilterNamingOnlyDeletedTagsDoesNotEmptyTheList() {
        let model = SessionListViewModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""))
        model.adopt(folders: [F.folder(1)], openFolders: [F.folder(1)],
                    conversations: [F.summary(1, tags: [7])], tags: [F.tag(7)])
        model.setTagFilter(TagFilter(tagIDs: [42], mode: .matchAll))
        #expect(!model.activeFilter.isActive)
        #expect(model.folderGroups(searchText: "").first?.conversations.count == 1)
    }

    @MainActor
    @Test func aConfirmedTagWritePatchesOnlyItsOwnServersRow() {
        let client = CodegClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "")
        let model = SessionListViewModel(client: client)
        model.adopt(folders: [], openFolders: [], conversations: [F.summary(1, tags: [1])])
        model.applyTagChange(ConversationTagsChange(endpoint: "http://elsewhere", conversationID: 1, tagIDs: [5]))
        #expect(model.conversations[0].tagIds == [1])
        model.applyTagChange(ConversationTagsChange(endpoint: client.tagEndpoint, conversationID: 1, tagIDs: [1, 2]))
        #expect(model.conversations[0].tagIds == [1, 2])
    }
}
