import Testing
@testable import Codeg

/// One conversation's tag writes, one at a time, each outcome settling only
/// what nobody touched since (port of Android `TagAssignmentTest`).
@Suite struct TagAssignmentTests {
    @Test func writesGoOneAtATimeAndAToggleMadeMeanwhileGoesInTheNext() throws {
        var a = TagAssignment(confirmed: [])
        a.toggle(1)
        let first = try #require(a.nextWrite())
        #expect(first.add == [1])
        a.toggle(2) // while the first is out
        a.succeeded(first, server: [1])
        #expect(a.desired == [1, 2])
        let second = try #require(a.nextWrite())
        #expect(second.add == [2])
        #expect(second.remove.isEmpty)
        a.succeeded(second, server: [1, 2])
        #expect(a.nextWrite() == nil)
    }

    @Test func aRefusedAddDoesNotUndoTheAddMadeAgainSince() throws {
        var a = TagAssignment(confirmed: [])
        a.toggle(1) // add
        let first = try #require(a.nextWrite())
        a.toggle(1) // remove
        a.toggle(1) // add again
        a.failed(first)
        // The newest intent stands, and goes out next.
        #expect(a.desired == [1])
        #expect(try #require(a.nextWrite()).add == [1])
    }

    @Test func aRefusalPutsBackWhatItSentAndNothingElse() throws {
        var a = TagAssignment(confirmed: [3])
        a.toggle(3) // remove
        let write = try #require(a.nextWrite())
        #expect(write.remove == [3])
        a.failed(write)
        #expect(a.desired == [3])
        #expect(a.nextWrite() == nil)
    }

    @Test func aSuccessAdoptsTheServersWordForWhatNobodyTouchedSince() throws {
        var a = TagAssignment(confirmed: [5])
        a.toggle(1)
        let write = try #require(a.nextWrite())
        a.toggle(2)
        // Another client took 5 off meanwhile.
        a.succeeded(write, server: [1])
        #expect(a.desired == [1, 2])
        #expect(a.confirmed == [1])
    }

    @Test func aCreatedTagIsTurnedOnOnce() throws {
        var a = TagAssignment(confirmed: [1])
        a.turnOn(1)
        #expect(a.nextWrite() == nil)
        a.turnOn(9)
        #expect(try #require(a.nextWrite()).add == [9])
    }

    @Test func aWriteIsSortedWhateverOrderTheTogglesCameIn() throws {
        var a = TagAssignment(confirmed: [8, 4])
        a.toggle(7)
        a.toggle(3)
        a.toggle(8)
        a.toggle(4)
        let write = try #require(a.nextWrite())
        #expect(write.add == [3, 7])
        #expect(write.remove == [4, 8])
    }
}
