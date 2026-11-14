import Foundation
import Testing
@testable import Codeg

/// `JSON.stringify` of an object literal: keys in the order given.
private func stringify(_ pairs: KeyValuePairs<String, Any>) -> String {
    func fragment(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    return "{" + pairs.map { "\(fragment($0.key)):\(fragment($0.value))" }.joined(separator: ",") + "}"
}

private let sent = Date(timeIntervalSince1970: 1_790_000_000)

private func user(_ id: String, _ text: String) -> MessageTurn {
    MessageTurn(id: id, role: .user, blocks: [.text(text)], timestamp: sent)
}

private func write(_ id: String, _ path: String) -> MessageTurn {
    MessageTurn(id: id, role: .assistant, blocks: [
        .toolUse(id: "\(id)-call", name: "Write",
                 inputPreview: stringify(["file_path": path, "content": "x\n"]), status: .unknown, meta: nil),
    ], timestamp: sent)
}

private func edits(_ id: String, _ path: String, _ changes: [(String, String)]) -> MessageTurn {
    MessageTurn(id: id, role: .assistant, blocks: changes.enumerated().map { index, change in
        ContentBlock.toolUse(id: "\(id)-edit-\(index)", name: "Edit",
                 inputPreview: stringify(["file_path": path, "old_string": change.0, "new_string": change.1]),
                 status: .unknown, meta: nil)
    }, timestamp: sent)
}

private func reply(_ id: String) -> MessageTurn {
    MessageTurn(id: id, role: .assistant, blocks: [.text("done")], timestamp: sent)
}

/// Port of the web's `message-nav-entries.test.ts` (codeg 0.44). Not ported:
/// the sub-agent cases (no sub-agent rows in v1), the entry-identity cases
/// (Swift values have none to keep), and `mergeFileChangesByPath`'s diff
/// joining (no inline diffs) — its per-file merge is the file count below.
@Suite struct MessageNavEntriesTests {
    // Global transcript: turn-0 … turn-5. The window starts at turn-4.
    private let earlier = [user("turn-0", "first"), write("turn-1", "/repo/a.ts"),
                           user("turn-2", "second"), reply("turn-3")]
    private let loaded = [user("turn-4", "third"), write("turn-5", "/repo/b.ts")]

    private func build(_ earlier: [MessageTurn]?, _ count: Int, _ loaded: [MessageTurn]) -> [MessageNavEntry] {
        MessageNavEntries.build(.init(earlierTurns: earlier, earlierUserCount: count, loadedTurns: loaded))
    }

    @Test func listsEveryMessageNumberingTheEarlierOnesFirst() {
        let entries = build(earlier, 2, loaded)
        #expect(entries.map(\.ordinal) == [1, 2, 3])
        #expect(entries.map(\.label) == ["first", "second", "third"])
        #expect(entries.map(\.globalIndex) == [0, 2, nil], "a loaded message is scrolled to, not paged in")
        #expect(entries.map(\.fileCount) == [1, 0, 1])
    }

    @Test func saysWhenEachMessageWasSent() {
        let later = MessageTurn(id: "turn-2", role: .user, blocks: [.text("second")],
                                timestamp: sent.addingTimeInterval(60))
        let entries = build(nil, 0, [user("turn-1", "first"), later])
        #expect(entries.map(\.sentAt) == [sent, sent.addingTimeInterval(60)])
    }

    @Test func numbersTheLoadedMessagesOnFromTheUnlistedOnesAboveThem() {
        let entries = build(nil, 2, loaded)
        #expect(entries.map(\.ordinal) == [3])
        #expect(entries.map(\.label) == ["third"])
    }

    @Test func collectsARoundsFilesAcrossTheWindowStart() {
        // The window starts mid-round: the prompt is above it, the edit inside.
        let entries = build([user("turn-0", "first"), reply("turn-1")], 1,
                            [write("turn-2", "/repo/c.ts"), user("turn-3", "next")])
        #expect(entries.map(\.label) == ["first", "next"])
        #expect(entries[0].fileCount == 1)
        #expect(entries[0].globalIndex == 0)
    }

    @Test func listsAMessageHeldByBothListsOnceWhereTheHistoryPutsIt() {
        let entries = build(earlier, 2, loaded + [user("turn-2", "second")])
        #expect(entries.map(\.turnID) == ["turn-0", "turn-2", "turn-4"])
        #expect(entries.map(\.ordinal) == [1, 2, 3])
        #expect(entries.map(\.globalIndex) == [0, nil, nil], "it jumps to the copy that renders")
    }

    @Test func prefersTheLoadedCopyOfAMessageOverItsOutlineEntry() {
        let entries = build([user("turn-0", "first")], 1, [user("turn-0", "first")])
        #expect(entries.count == 1)
        #expect(entries[0].globalIndex == nil)
    }

    @Test func countsAFileTheRoundChangedSeveralTimesOnce() {
        let entries = build(nil, 0, [
            user("turn-0", "first"),
            edits("turn-1", "/repo/a.ts", [("one", "uno"), ("two", "dos\ntres")]),
            write("turn-2", "/repo/b.ts"),
        ])
        #expect(entries[0].fileCount == 2)
        // a.ts +3 −2. b.ts: a Write of "x\n" is ONE line here — the activity
        // rows' count; the web navigator counts `split("\n").length` (2).
        #expect(entries[0].additions == 4)
        #expect(entries[0].deletions == 2)
    }

    @Test func repliesAheadOfTheFirstMessageBelongToNone() {
        let entries = build(nil, 3, [write("turn-9", "/repo/z.ts"), user("turn-10", "next")])
        #expect(entries.map(\.turnID) == ["turn-10"])
        #expect(entries[0].ordinal == 4)
        #expect(entries[0].fileCount == 0)
    }

    @Test func readsOnlyEditsAndTheirFiles() {
        let read = MessageTurn(id: "r", role: .assistant, blocks: [
            .toolUse(id: "c1", name: "Read", inputPreview: stringify(["file_path": "/repo/a.ts"]),
                     status: .unknown, meta: nil),
        ], timestamp: sent)
        #expect(build(nil, 0, [user("u", "look"), read])[0].fileCount == 0)
    }

    @Test func labelsAreTheFirstTextTrimmedAndCut() {
        let long = String(repeating: "a", count: 90)
        let turn = MessageTurn(id: "u", role: .user, blocks: [.text(""), .text("  \(long)  ")], timestamp: sent)
        #expect(MessageNavEntries.label(of: turn) == String(repeating: "a", count: 77) + "...")
        let image = MessageTurn(id: "u", role: .user,
                                blocks: [.image(ImageData(data: "", mimeType: "image/png", uri: nil))], timestamp: sent)
        #expect(MessageNavEntries.label(of: image) == nil, "the row says \"User message\"")
        #expect(MessageNavEntries.label(of: user("u", "  hi\n")) == "hi")
    }
}

/// Port of the web's `use-conversation-outline.test.tsx` onto the outline's
/// state transitions. The hashes are arbitrary strings: iOS compares the
/// server's fingerprints and never computes one (the web extends its FNV
/// chain to check a shorter prefix; here the anchor moves with each
/// seam-proven page instead). Not ported: the StrictMode and "parsed before
/// served" cases (React-only), and "one conversation's outline to another"
/// (the outline lives in a per-conversation view model).
@Suite struct NavigatorOutlineTests {
    private func turns(_ count: Int) -> [MessageTurn] {
        (0..<count).map { i in
            MessageTurn(id: "turn-\(i)", role: i % 2 == 0 ? .user : .assistant,
                        blocks: [.text("t\(i)")], timestamp: sent.addingTimeInterval(Double(i)))
        }
    }

    private func hash(_ count: Int) -> String { "h\(count)" }

    private func outline(_ count: Int, hash: String? = nil) -> ConversationOutline {
        ConversationOutline(turns: turns(count), turnsTotal: 8, prefixHash: hash ?? self.hash(count))
    }

    private func window(_ offset: Int, hash: String? = nil, outlineRoute: Bool = true) -> TranscriptWindow {
        var w = TranscriptWindow(offset: offset, total: 8, prefixHash: hash ?? self.hash(offset))
        w.userTurnsBefore = outlineRoute ? offset / 2 : nil
        return w
    }

    @Test func fetchesNothingWithNothingAboveTheWindowOrWithoutTheRoute() {
        let o = NavigatorOutline()
        #expect(o.fetchKey(for: nil) == nil, "no window: everything is loaded")
        #expect(o.fetchKey(for: window(0)) == nil)
        #expect(o.fetchKey(for: window(4, outlineRoute: false)) == nil)
        #expect(o.state(for: window(4, outlineRoute: false)) == .unsupported)
        #expect(o.state(for: window(0)) == .allLoaded)
    }

    // The outline's transitions are `mutating`; they're called outside the
    // expectation macros, which take their operands apart into closures.

    /// Start a fetch for `window` and require that one starts.
    private func begin(_ o: inout NavigatorOutline, _ window: TranscriptWindow) throws -> OutlineAnchor {
        let key = o.beginFetch(for: window)
        return try #require(key)
    }

    /// Fetch for `window` and land `result` — one round trip.
    private func fetch(_ o: inout NavigatorOutline, _ window: TranscriptWindow,
                       _ result: ConversationOutline?) throws {
        let key = try begin(&o, window)
        o.land(result, for: key)
    }

    @Test func loadsTheHistoryAboveTheWindow() throws {
        var o = NavigatorOutline()
        let key = try begin(&o, window(4))
        #expect(key == OutlineAnchor(offset: 4, prefixHash: "h4"))
        #expect(o.state(for: window(4)) == .loading)
        #expect(o.fetchKey(for: window(4)) == nil, "one fetch at a time")
        let landed = o.land(outline(4), for: key)
        #expect(landed)
        #expect(o.state(for: window(4)) == .ready)
        #expect(o.earlierTurns(for: window(4))?.map(\.id) == ["turn-0", "turn-1", "turn-2", "turn-3"])
        #expect(o.fetchKey(for: window(4)) == nil, "held")
    }

    @Test func keepsServingTheWindowAsOlderPagesArePrepended() throws {
        var o = NavigatorOutline()
        try fetch(&o, window(4), outline(4))
        o.windowDidPrepend(from: OutlineAnchor(window(4)), to: OutlineAnchor(window(2)))
        #expect(o.state(for: window(2)) == .ready)
        #expect(o.earlierTurns(for: window(2))?.map(\.id) == ["turn-0", "turn-1"])
        #expect(o.fetchKey(for: window(2)) == nil, "not fetched again")
    }

    @Test func refetchesOnceTheWindowStartsBelowTheOutline() throws {
        var o = NavigatorOutline()
        try fetch(&o, window(4), outline(4))
        #expect(o.state(for: window(6)) == .loading)
        let next = try begin(&o, window(6))
        #expect(next.offset == 6)
        o.land(outline(6), for: next)
        #expect(o.earlierTurns(for: window(6))?.count == 6)
    }

    @Test func neverShowsAnOutlineWhoseHistoryDiffersFromTheWindows() throws {
        var o = NavigatorOutline()
        let rewritten = window(4, hash: "00000000000000ff")
        try fetch(&o, rewritten, outline(4))
        #expect(o.state(for: rewritten) == .failed)
        #expect(o.earlierTurns(for: rewritten) == nil)
        // Not fetched again for the same window…
        #expect(o.fetchKey(for: rewritten) == nil)
        // …until the window moves.
        try fetch(&o, window(4), outline(4))
        #expect(o.state(for: window(4)) == .ready)
    }

    @Test func retriesAFailedFetchOnRequest() throws {
        var o = NavigatorOutline()
        try fetch(&o, window(4), nil)
        #expect(o.state(for: window(4)) == .failed)
        o.retry()
        try fetch(&o, window(4), outline(4))
        #expect(o.state(for: window(4)) == .ready)
    }

    @Test func aFetchForAnOlderWindowIsReplacedAndRefusedWhenItLands() throws {
        var o = NavigatorOutline()
        let first = try begin(&o, window(4))
        // The window was reset further down while the first fetch was out.
        let second = try begin(&o, window(6))
        let staleLanded = o.land(outline(4), for: first)
        #expect(!staleLanded)
        #expect(o.state(for: window(6)) == .loading)
        let landed = o.land(outline(6), for: second)
        #expect(landed)
        #expect(o.earlierTurns(for: window(6))?.count == 6)
    }

    @Test func doesNotFailTheCurrentWindowOverAnOlderWindowsFailedFetch() throws {
        var o = NavigatorOutline()
        let stale = try begin(&o, window(4))
        let current = try begin(&o, window(6))
        let staleLanded = o.land(nil, for: stale)
        #expect(!staleLanded)
        #expect(o.state(for: window(6)) == .loading)
        o.land(outline(6), for: current)
        #expect(o.state(for: window(6)) == .ready)
    }

    @Test func dropsAServedOutlineOnceTheShorterPrefixItCoversWasRewritten() throws {
        var o = NavigatorOutline()
        try fetch(&o, window(4), outline(4))
        // The window moved up to 2 — but by a re-anchor, not a seam-proven page.
        let moved = window(2, hash: "00000000000000ab")
        #expect(o.state(for: moved) == .loading)
        #expect(o.fetchKey(for: moved) == OutlineAnchor(offset: 2, prefixHash: "00000000000000ab"))
    }

    @Test func anAnchorLeftBehindStaysBehind() {
        let a4 = OutlineAnchor(offset: 4, prefixHash: "h4")
        let a2 = OutlineAnchor(offset: 2, prefixHash: "h2")
        let a1 = OutlineAnchor(offset: 1, prefixHash: "h1")
        #expect(OutlineValidity.anchorAfterPrepend(a4, before: a4, after: a2) == a2)
        #expect(OutlineValidity.anchorAfterPrepend(a4, before: a2, after: a1) == a4)
        #expect(OutlineValidity.anchorAfterPrepend(nil, before: a4, after: a2) == nil)
    }

    @Test func acceptsOnlyAnOutlineCutAtTheWindowStart() {
        let key = OutlineAnchor(offset: 4, prefixHash: "h4")
        #expect(OutlineValidity.accepts(outline(4), for: key))
        #expect(!OutlineValidity.accepts(outline(5, hash: "h4"), for: key))
        #expect(!OutlineValidity.accepts(outline(4, hash: "h5"), for: key))
    }
}

@Suite struct OlderTurnsPagingTests {
    @Test func asksForEverythingDownToTheTargetWithinTheBounds() {
        #expect(OlderTurnsPaging.limit(offset: 480, target: 400) == 120, "at least a normal page")
        #expect(OlderTurnsPaging.limit(offset: 480, target: 100) == 380)
        #expect(OlderTurnsPaging.limit(offset: 2_000, target: 0) == 500, "the server's clamp")
    }
}

@Suite struct NavigatorWireTests {
    @Test func theOutlineDecodes() throws {
        let outline = try CodegJSON.decoder.decode(ConversationOutline.self, from: Data(#"""
        {"turns":[
          {"id":"turn-0","role":"user","blocks":[{"type":"text","text":"first"}],"timestamp":"2026-10-01T08:00:00Z"},
          {"id":"turn-1","role":"assistant","blocks":[{"type":"tool_use","tool_use_id":"c1","tool_name":"Write","input_preview":"{\"file_path\":\"/r/a.ts\",\"content\":\"x\"}"}],"timestamp":"2026-10-01T08:00:01Z"},
          {"id":"turn-2","role":"system","blocks":[],"timestamp":"2026-10-01T08:00:02Z"}
        ],"turns_total":9,"prefix_hash":"00000000000000ff"}
        """#.utf8))
        #expect(outline.turns.map(\.id) == ["turn-0", "turn-1", "turn-2"])
        #expect(outline.turnsTotal == 9)
        #expect(outline.prefixHash == "00000000000000ff")
    }

    private func detailJSON(extra: String) -> Data {
        Data("""
        {"summary":{"id":1,"folder_id":2,"title":"t","agent_type":"claude_code","status":"completed",
        "message_count":2,"created_at":"2026-11-14T00:00:00Z","updated_at":"2026-11-14T00:00:00Z"},
        "turns":[],"turns_offset":120,"turns_total":240,"prefix_hash":"00000000000000aa"\(extra)}
        """.utf8)
    }

    @Test func theDetailSaysHowManyMessagesAreAboveTheWindow() throws {
        let detail = try CodegJSON.decoder.decode(ConversationDetail.self, from: detailJSON(
            extra: #","user_turns_before_offset":57"#))
        #expect(detail.userTurnsBeforeOffset == 57)
        #expect(TranscriptWindow(detail)?.userTurnsBefore == 57)
    }

    @Test func anOlderServersDetailStillWindowsWithoutIt() throws {
        let detail = try CodegJSON.decoder.decode(ConversationDetail.self, from: detailJSON(extra: ""))
        #expect(detail.userTurnsBeforeOffset == nil)
        let window = try #require(TranscriptWindow(detail))
        #expect(window.offset == 120)
        #expect(window.userTurnsBefore == nil, "no outline route: the navigator won't ask")
    }

    @Test func aPageCarriesTheCountWhenTheServerHasIt() throws {
        let base = #""turns":[],"turns_offset":0,"turns_total":240,"prefix_hash":"00000000000000bb","prefix_hash_before_index":"00000000000000aa""#
        let page = try CodegJSON.decoder.decode(ConversationTurnsPage.self, from: Data(
            "{\(base),\"user_turns_before_offset\":0}".utf8))
        #expect(page.userTurnsBeforeOffset == 0)
        let older = try CodegJSON.decoder.decode(ConversationTurnsPage.self, from: Data("{\(base)}".utf8))
        #expect(older.userTurnsBeforeOffset == nil, "paging goes on working against an older server")
    }

    @Test func theRequestIsCamelCase() throws {
        let data = try CodegJSON.encoder.encode(ConversationOutlineBody(conversationId: 7, beforeIndex: 120))
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try #require(json as? [String: Int])
        #expect(object == ["conversationId": 7, "beforeIndex": 120])
    }
}
