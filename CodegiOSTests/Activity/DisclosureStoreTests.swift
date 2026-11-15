import Foundation
import Observation
import Testing
@testable import Codeg

/// Set from an observation callback, which may not capture a `var`.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

/// What the transcript's rows remember of the reader's toggles across the
/// list recycling them (``DisclosureStore``).
@MainActor
struct DisclosureStoreTests {
    /// Whether `change` wakes a view that drew by running `read`.
    private func wakes(_ read: () -> Void, _ change: () -> Void) -> Bool {
        let flag = ObservationFlag()
        withObservationTracking {
            read()
        } onChange: {
            flag.fired = true
        }
        change()
        return flag.fired
    }

    // MARK: - Choices

    @Test func aRowNobodyToggledShowsItsOwnDefault() {
        let store = DisclosureStore()
        #expect(store.choice("tool-1/tool") == nil)
        // An auto-expanded row (failed, awaiting the user) stays open…
        #expect(store.isOpen("tool-1/tool", default: true))
        // …and a folded-by-default one stays shut.
        #expect(!store.isOpen("k-run/thought", default: false))
    }

    @Test func aChoiceOutlivesTheRowThatMadeIt() {
        let store = DisclosureStore()
        store.set(true, for: "k-run/thought")
        // The row scrolled away and back is a new view: it reads the same key.
        #expect(store.choice("k-run/thought") == true)
        #expect(store.isOpen("k-run/thought", default: false))
        // Closing a row that opened by itself sticks too.
        store.set(false, for: "tool-1/tool")
        #expect(!store.isOpen("tool-1/tool", default: true))
    }

    @Test func eachKeyKeepsItsOwnChoice() {
        let store = DisclosureStore()
        store.set(true, for: "toolgroup-1/group")
        #expect(store.choice("toolgroup-1/tool:a/tool") == nil)
        #expect(store.choice("toolgroup-2/group") == nil)
        store.set(false, for: "toolgroup-1/tool:a/tool")
        #expect(store.choice("toolgroup-1/group") == true)
    }

    @Test func clearingAChoiceGivesTheRowItsDefaultBack() {
        let store = DisclosureStore()
        store.set(false, for: "tool-1/tool")
        store.set(nil, for: "tool-1/tool")
        #expect(store.choice("tool-1/tool") == nil)
        #expect(store.isOpen("tool-1/tool", default: true))
        // Clearing a key never chosen for records nothing.
        store.set(nil, for: "tool-2/tool")
        #expect(store.choice("tool-2/tool") == nil)
    }

    @Test func aToggleFlipsWhatTheRowShows() {
        let store = DisclosureStore()
        store.toggle("tool-1/tool", default: true)
        #expect(store.choice("tool-1/tool") == false)
        store.toggle("tool-1/tool", default: true)
        #expect(store.choice("tool-1/tool") == true)
    }

    @Test func eachScreenHasItsOwnStore() {
        // codeg turn ids are not globally unique: another conversation's
        // `turn-3#thought@1` is another row.
        let one = DisclosureStore()
        let other = DisclosureStore()
        one.set(true, for: "turn-3#thought@1/thought")
        #expect(other.choice("turn-3#thought@1/thought") == nil)
    }

    // MARK: - Keys

    @Test func aKeyNamesTheRowAndTheDisclosureInIt() {
        #expect(DisclosureStore.key(scope: "tool-1", name: "tool") == "tool-1/tool")
        // A nested level is a scope of its own.
        let member = DisclosureStore.key(scope: "toolgroup-1", name: "tool:a")
        #expect(DisclosureStore.key(scope: member, name: "tool") == "toolgroup-1/tool:a/tool")
        // Outside a row there is nowhere to keep it.
        #expect(DisclosureStore.key(scope: nil, name: "tool") == nil)
    }

    // MARK: - Who is woken

    @Test func aChoiceWakesTheRowThatReadsIt() {
        let store = DisclosureStore()
        store.set(true, for: "a")
        #expect(wakes({ _ = store.choice("a") }, { store.set(false, for: "a") }))
        // Writing what is already there wakes nobody.
        #expect(!wakes({ _ = store.choice("a") }, { store.set(false, for: "a") }))
    }

    @Test func aChoiceLeavesTheOtherRowsAlone() {
        let store = DisclosureStore()
        store.set(true, for: "a")
        store.set(true, for: "b")
        #expect(!wakes({ _ = store.choice("a") }, { store.set(false, for: "b") }))
        // A first choice for a new key does not wake a row reading its own.
        #expect(!wakes({ _ = store.choice("a") }, { store.set(true, for: "c") }))
    }

    @Test func aFirstChoiceWakesTheRowsStillOnTheirDefault() {
        let store = DisclosureStore()
        // A key with no choice yet has no entry to watch: its row must still
        // hear of the first one.
        #expect(wakes({ _ = store.choice("a") }, { store.set(true, for: "a") }))
    }
}
