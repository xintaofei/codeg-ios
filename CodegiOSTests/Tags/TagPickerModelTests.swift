import Foundation
import Testing
@testable import Codeg

/// The tag picker against a server answered by hand (port of Android
/// `TagPickerControllerTest`): one writer per conversation and server, edits
/// one at a time, and a read that lands late binds nothing.
@MainActor
@Suite struct TagPickerModelTests {
    private typealias F = TagFixtures
    private let tag1 = TagFixtures.tag(1, name: "one")

    /// A registry of the test's own (the shared one is the app's), told
    /// nothing outward.
    private func registry() -> TagWriteRegistry {
        let registry = TagWriteRegistry()
        registry.onConfirmed = { _, _ in }
        registry.onTagCreated = { _ in }
        return registry
    }

    /// Open and wait until the tags have been read.
    private func openReady(_ picker: TagPickerModel, _ conversation: ConversationSummary,
                           _ server: FakeTagServer, endpoint: String = "s") async {
        picker.open(conversation, api: server, endpoint: endpoint)
        _ = await waitUntil { picker.isReady }
    }

    @Test func aReadThatLandsAfterANewerOpenBindsNothing() async {
        let a = FakeTagServer()
        let gate = TestGate()
        a.listGate = gate
        let b = FakeTagServer()
        b.tags = [tag1, F.tag(2, name: "two")]
        let picker = TagPickerModel(registry: registry())
        picker.open(F.summary(7), api: a, endpoint: "a")
        await openReady(picker, F.summary(7), b, endpoint: "b")
        gate.open() // the first opening's server answers last
        await letQueuedWorkRun()
        #expect(picker.tags?.map(\.id) == [1, 2], "the newer opening's tags stand")
        picker.toggle(tag1)
        #expect(await waitUntil { b.writes.count == 1 })
        #expect(a.writes.isEmpty)
        #expect(b.writes == [.init(conversation: 7, add: [1], remove: [])])
    }

    @Test func nothingTogglesBeforeThisOpeningHasReadTheTags() async {
        let server = FakeTagServer()
        let gate = TestGate()
        server.listGate = gate
        let picker = TagPickerModel(registry: registry())
        picker.open(F.summary(4), api: server, endpoint: "s")
        picker.toggle(tag1)
        picker.create(name: "new", global: true)
        gate.open()
        _ = await waitUntil { picker.isReady }
        await letQueuedWorkRun()
        #expect(server.writes.isEmpty)
        #expect(server.tags.count == 1, "no tag was created either")
    }

    @Test func reopeningAConversationStillWritingTakesOverItsOneWriter() async {
        let server = FakeTagServer()
        let picker = TagPickerModel(registry: registry())
        await openReady(picker, F.summary(1), server)
        picker.toggle(tag1) // add, held by the server
        #expect(await waitUntil { server.outstanding == 1 })
        await openReady(picker, F.summary(2), server)
        // The caller's summary doesn't know of the add yet.
        await openReady(picker, F.summary(1), server)
        #expect(picker.desired == [1])
        picker.toggle(tag1) // remove: waits for the add rather than racing it
        await letQueuedWorkRun()
        #expect(server.writes.count == 1)
        server.answer()
        #expect(await waitUntil { server.writes.count == 2 })
        #expect(server.writes.last == .init(conversation: 1, add: [], remove: [1]))
        server.answer()
        #expect(await waitUntil { server.held[1] == [] && server.outstanding == 0 })
        #expect(picker.desired.isEmpty)
    }

    @Test func aSwitchToAnotherServerStartsOverThere() async {
        let x = FakeTagServer()
        let y = FakeTagServer()
        let picker = TagPickerModel(registry: registry())
        await openReady(picker, F.summary(3), x, endpoint: "x")
        await openReady(picker, F.summary(3), y, endpoint: "y")
        picker.toggle(tag1)
        #expect(await waitUntil { y.writes.count == 1 })
        #expect(x.writes.isEmpty)
    }

    @Test func aTagCreatedAsThePickerMovesOnStillGoesOnItsConversation() async {
        let server = FakeTagServer()
        let gate = TestGate()
        server.createGate = gate
        let picker = TagPickerModel(registry: registry())
        await openReady(picker, F.summary(5), server)
        picker.create(name: "new", global: true)
        await openReady(picker, F.summary(6), server) // before the create lands
        gate.open()
        #expect(await waitUntil { server.writes.count == 1 })
        #expect(server.writes == [.init(conversation: 5, add: [9], remove: [])])
    }

    @Test func aReopenWhileATagIsBeingCreatedKeepsTheOneWriter() async {
        let server = FakeTagServer()
        let gate = TestGate()
        server.createGate = gate
        let picker = TagPickerModel(registry: registry())
        await openReady(picker, F.summary(8), server)
        picker.create(name: "new", global: true)
        await openReady(picker, F.summary(9), server)
        await openReady(picker, F.summary(8), server) // the create is still out
        gate.open()
        #expect(await waitUntil { server.writes.count == 1 })
        picker.toggle(tag1)
        await letQueuedWorkRun()
        // The created tag's write first; the toggle waits for it instead of racing it.
        #expect(server.writes == [.init(conversation: 8, add: [9], remove: [])])
        server.answer()
        #expect(await waitUntil { server.writes.count == 2 })
        #expect(server.writes.last == .init(conversation: 8, add: [1], remove: []))
        server.answer()
        #expect(await waitUntil { server.outstanding == 0 && picker.desired == [1, 9] })
    }

    @Test func anEarlierCreateCannotMakeANewerOpeningReady() async {
        let server = FakeTagServer()
        let createGate = TestGate()
        server.createGate = createGate
        let picker = TagPickerModel(registry: registry())
        await openReady(picker, F.summary(5), server)
        picker.create(name: "new", global: true)
        let readGate = TestGate()
        server.listGate = readGate
        picker.open(F.summary(5), api: server, endpoint: "s") // its read is held
        createGate.open()
        // The created tag still goes on its conversation…
        #expect(await waitUntil { server.writes.count == 1 })
        await letQueuedWorkRun()
        // …but this opening has read nothing yet, so nothing is actionable.
        #expect(picker.tags == nil)
        #expect(!picker.isReady)
        picker.toggle(tag1)
        await letQueuedWorkRun()
        #expect(server.writes.count == 1)
        readGate.open()
        #expect(await waitUntil { picker.isReady })
        #expect(picker.tags?.contains(where: { $0.id == 9 }) == true)
    }

    @Test func twoPickersOnOneConversationShareItsWriter() async {
        let server = FakeTagServer()
        server.tags = [tag1, F.tag(2, name: "two")]
        let shared = registry()
        let list = TagPickerModel(registry: shared)
        let detail = TagPickerModel(registry: shared)
        await openReady(list, F.summary(4), server)
        await openReady(detail, F.summary(4), server)
        #expect(list.session === detail.session)
        list.toggle(tag1)
        detail.toggle(F.tag(2))
        #expect(await waitUntil { server.writes.count == 1 })
        await letQueuedWorkRun()
        #expect(server.writes.count == 1, "the second toggle waits for the first write")
        #expect(detail.desired == [1, 2], "both pickers show both toggles")
        server.answer()
        #expect(await waitUntil { server.writes.count == 2 })
        #expect(server.writes.last == .init(conversation: 4, add: [2], remove: []))
    }

    @Test func aRefusalPutsTheToggleBackAndSaysSo() async {
        let server = FakeTagServer()
        let picker = TagPickerModel(registry: registry())
        await openReady(picker, F.summary(2, tags: [1]), server)
        picker.toggle(tag1) // remove
        #expect(picker.desired.isEmpty, "shown at once")
        #expect(await waitUntil { server.outstanding == 1 })
        server.refuse()
        #expect(await waitUntil { picker.error != nil })
        #expect(picker.desired == [1])
        picker.dismissError()
        #expect(picker.error == nil)
    }

    @Test func aSettledConversationIsForgottenOnceNoPickerShowsIt() async {
        let server = FakeTagServer()
        let shared = registry()
        let picker = TagPickerModel(registry: shared)
        await openReady(picker, F.summary(3), server)
        picker.toggle(tag1)
        #expect(await waitUntil { server.outstanding == 1 })
        picker.close()
        #expect(shared.hasSession(endpoint: "s", conversationID: 3), "still owes a write")
        server.answer()
        #expect(await waitUntil { !shared.hasSession(endpoint: "s", conversationID: 3) })
    }

    @Test func aLoadFailureLeavesNothingToToggle() async {
        final class Failing: ConversationTagsAPI {
            func listConversationTags() async throws -> [ConversationTag] { throw APIError.transport("down") }
            func listFolders() async throws -> [FolderDetail] { [] }
            func createConversationTag(folderId: Int?, name: String, color: String) async throws -> ConversationTag {
                throw APIError.transport("down")
            }
            func updateConversationTags(conversationId: Int, add: [Int], remove: [Int]) async throws -> ConversationSummary {
                Issue.record("no write may go out")
                throw APIError.transport("down")
            }
        }
        let picker = TagPickerModel(registry: registry())
        picker.open(F.summary(1), api: Failing(), endpoint: "s")
        #expect(await waitUntil { picker.error != nil })
        #expect(picker.tags?.isEmpty == true)
        #expect(!picker.isReady)
        picker.toggle(tag1)
        await letQueuedWorkRun()
    }
}
