import Foundation

/// One conversation's tags as the user wants them (`desired`) and as the
/// server last confirmed them (`confirmed`), with the writes between the two
/// sent one at a time. Pure, for tests (port of Android `TagAssignment`).
///
/// Every toggle stamps its tag with a rising clock. A write carries the clock
/// it was computed at, so its outcome only settles the tags nobody touched
/// since: a success adopts the server's word for them (another client's change
/// included), a refusal puts them back where the server has them — and a
/// toggle made while the write was out stands either way, to go in the next.
struct TagAssignment: Equatable, Sendable {
    /// What one `update_conversation_tags` request sends, and the clock it was
    /// computed at.
    struct Write: Equatable, Sendable {
        let add: [Int]
        let remove: [Int]
        let at: Int
    }

    private(set) var confirmed: Set<Int>
    private var wanted: Set<Int>
    /// The clock of each tag's latest toggle.
    private var touched: [Int: Int] = [:]
    private var clock = 0

    init(confirmed: Set<Int>) {
        self.confirmed = confirmed
        self.wanted = confirmed
    }

    /// What the user wants on the conversation — shown at once.
    var desired: Set<Int> { wanted }

    mutating func toggle(_ tagID: Int) {
        if wanted.contains(tagID) { wanted.remove(tagID) } else { wanted.insert(tagID) }
        clock += 1
        touched[tagID] = clock
    }

    /// Make sure `tagID` is on (a tag just created for this conversation).
    mutating func turnOn(_ tagID: Int) {
        if !wanted.contains(tagID) { toggle(tagID) }
    }

    /// What to send next, or nil when the server already has what is wanted.
    /// Sorted, so a write reads the same however the sets iterate.
    func nextWrite() -> Write? {
        let add = wanted.subtracting(confirmed).sorted()
        let remove = confirmed.subtracting(wanted).sorted()
        guard !add.isEmpty || !remove.isEmpty else { return nil }
        return Write(add: add, remove: remove, at: clock)
    }

    /// The server applied `write` and now holds `server`.
    mutating func succeeded(_ write: Write, server: Set<Int>) {
        let untouched = wanted.union(confirmed).union(server).filter { untouchedSince(write, $0) }
        confirmed = server
        for id in untouched {
            if server.contains(id) { wanted.insert(id) } else { wanted.remove(id) }
        }
    }

    /// The server refused `write`: what it sent, untouched since, goes back.
    mutating func failed(_ write: Write) {
        for id in write.add + write.remove where untouchedSince(write, id) {
            if confirmed.contains(id) { wanted.insert(id) } else { wanted.remove(id) }
        }
    }

    private func untouchedSince(_ write: Write, _ id: Int) -> Bool {
        (touched[id] ?? 0) <= write.at
    }
}
