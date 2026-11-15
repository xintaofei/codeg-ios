import Foundation
import Testing
@testable import Codeg

/// The manager's reorder (web: drag in `ConversationTagsManager`): a drop
/// reported the way `.onMove` reports it, and Move Up / Move Down, both coming
/// out as the scope's complete new order — or nothing to send.
@Suite struct TagOrderTests {
    private let ids = [1, 2, 3, 4]

    @Test func aDropLandsBeforeTheRowThatWasAtTheDestination() {
        #expect(TagOrder.moving(ids, fromOffsets: [0], toOffset: 2) == [2, 1, 3, 4])
        #expect(TagOrder.moving(ids, fromOffsets: [3], toOffset: 0) == [4, 1, 2, 3])
        #expect(TagOrder.moving(ids, fromOffsets: [1], toOffset: 4) == [1, 3, 4, 2], "the end")
        #expect(TagOrder.moving(ids, fromOffsets: [2], toOffset: 1) == [1, 3, 2, 4])
    }

    @Test func severalRowsMoveTogetherInTheirOrder() {
        #expect(TagOrder.moving(ids, fromOffsets: [0, 2], toOffset: 4) == [2, 4, 1, 3])
        #expect(TagOrder.moving(ids, fromOffsets: [1, 3], toOffset: 0) == [2, 4, 1, 3])
    }

    @Test func aDropInPlaceSendsNothing() {
        #expect(TagOrder.moving(ids, fromOffsets: [1], toOffset: 1) == nil)
        #expect(TagOrder.moving(ids, fromOffsets: [1], toOffset: 2) == nil, "just after itself is where it was")
        #expect(TagOrder.moving(ids, fromOffsets: [], toOffset: 2) == nil)
        #expect(TagOrder.moving([7], fromOffsets: [0], toOffset: 1) == nil)
    }

    @Test func offsetsOutOfRangeAreIgnoredAndTheDestinationClamped() {
        #expect(TagOrder.moving(ids, fromOffsets: [9], toOffset: 0) == nil)
        #expect(TagOrder.moving(ids, fromOffsets: [0], toOffset: 99) == [2, 3, 4, 1])
        #expect(TagOrder.moving(ids, fromOffsets: [3], toOffset: -5) == [4, 1, 2, 3])
    }

    @Test func moveUpAndDownStopAtTheEdges() {
        #expect(TagOrder.shifting(ids, 3, by: -1) == [1, 3, 2, 4])
        #expect(TagOrder.shifting(ids, 3, by: 1) == [1, 2, 4, 3])
        #expect(TagOrder.shifting(ids, 1, by: -1) == nil)
        #expect(TagOrder.shifting(ids, 4, by: 1) == nil)
        #expect(TagOrder.shifting(ids, 42, by: 1) == nil, "not in this scope")
        #expect(TagOrder.shifting(ids, 2, by: 0) == nil)
    }

    @Test func aDropAgreesWithTheEquivalentMoveUpOrDown() {
        // Up one: from i to i - 1; down one: from i to i + 2 (before the row
        // after its neighbour).
        #expect(TagOrder.moving(ids, fromOffsets: [2], toOffset: 1) == TagOrder.shifting(ids, 3, by: -1))
        #expect(TagOrder.moving(ids, fromOffsets: [1], toOffset: 3) == TagOrder.shifting(ids, 2, by: 1))
    }
}
