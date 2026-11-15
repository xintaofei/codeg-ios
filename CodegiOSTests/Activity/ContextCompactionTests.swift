import Foundation
import Testing
@testable import Codeg

/// `src/lib/context-compaction.test.ts` and the payload half of
/// `context-compaction-card.test.tsx` (codeg 0.44), plus Android's
/// `ContextCompactionTest` (52f2021): both marker shapes, the versioned
/// payload, and the summary claim.
@MainActor
struct ContextCompactionTests {
    private static func meta(_ json: String) -> AnyJSON? { AnyJSON.parse(jsonString: json) }

    // MARK: - matches

    @Test("accepts the legacy boolean marker (codex ≤1.2.x, grok bridge)")
    func acceptsTheLegacyBooleanMarker() {
        #expect(ContextCompaction.matches(Self.meta(#"{"contextCompaction":true}"#)))
        // Grok stamps sibling token counts next to the marker.
        #expect(ContextCompaction.matches(Self.meta(#"{"contextCompaction":true,"tokensBefore":51777,"tokensAfter":4616}"#)))
    }

    @Test("accepts the versioned object (codex-acp 1.3.0+)")
    func acceptsTheVersionedObject() {
        // 1.3.0 emits the bare payload…
        #expect(ContextCompaction.matches(Self.meta(#"{"contextCompaction":{"version":1}}"#)))
        // …the schema reserves optional fields…
        #expect(ContextCompaction.matches(Self.meta(
            #"{"contextCompaction":{"version":1,"preTokens":51777,"postTokens":4616,"durationMs":3200,"trigger":"auto"}}"#)))
        // …and future versions keep matching.
        #expect(ContextCompaction.matches(Self.meta(#"{"contextCompaction":{"version":2}}"#)))
    }

    @Test("rejects non-marker shapes")
    func rejectsNonMarkerShapes() {
        #expect(!ContextCompaction.matches(nil))
        #expect(!ContextCompaction.matches(.null))
        #expect(!ContextCompaction.matches(.string("contextCompaction")))
        #expect(!ContextCompaction.matches(Self.meta("{}")))
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":false}"#)))
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":"true"}"#)))
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":1}"#)))
        // An object without a valid integer version ≥ 1 is not the versioned form.
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":{}}"#)))
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":{"version":0}}"#)))
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":{"version":1.5}}"#)))
        #expect(!ContextCompaction.matches(Self.meta(#"{"contextCompaction":{"version":"1"}}"#)))
    }

    @Test("routes the versioned marker to a compaction step, whatever the tool is named")
    func routesTheVersionedMarkerToACompaction() {
        let vm = ToolCallVM(id: "c1", rawName: "context_compaction", kind: "", state: .done,
                            input: nil, output: nil, content: nil, isError: false,
                            meta: Self.meta(#"{"contextCompaction":{"version":1}}"#))
        #expect(DescribeToolCall.kind(vm) == .compaction)
    }

    // MARK: - payload

    @Test("returns the versioned payload object")
    func returnsTheVersionedPayloadObject() {
        let payload = ContextCompaction.payload(Self.meta(#"{"contextCompaction":{"version":1,"preTokens":100,"postTokens":40}}"#))
        #expect(payload == Self.meta(#"{"version":1,"preTokens":100,"postTokens":40}"#))
    }

    @Test("returns no payload for the boolean marker and non-compaction meta")
    func returnsNoPayloadForTheBooleanMarker() {
        #expect(ContextCompaction.payload(Self.meta(#"{"contextCompaction":true}"#)) == nil)
        #expect(ContextCompaction.payload(Self.meta(#"{"contextCompaction":false}"#)) == nil)
        #expect(ContextCompaction.payload(Self.meta("{}")) == nil)
        #expect(ContextCompaction.payload(nil) == nil)
    }

    @Test("reads the versioned payload's figures")
    func readsTheVersionedPayloadsFigures() {
        let versioned = Self.meta(
            #"{"contextCompaction":{"version":1,"trigger":"auto","preTokens":180000,"postTokens":22000,"durationMs":5300}}"#)
        let tokens = ContextCompaction.tokens(versioned)
        #expect(tokens.before == 180000)
        #expect(tokens.after == 22000)
        #expect(ContextCompaction.durationMs(versioned) == 5300)
        #expect(ContextCompaction.trigger(versioned) == "auto")
        #expect(ContextCompaction.error(versioned) == nil)
    }

    @Test("reads grok's top-level counts next to the boolean marker")
    func readsGroksTopLevelCounts() {
        let grok = Self.meta(#"{"contextCompaction":true,"tokensBefore":51777,"tokensAfter":4616}"#)
        let tokens = ContextCompaction.tokens(grok)
        #expect(tokens.before == 51777)
        #expect(tokens.after == 4616)
        // The boolean shape has no payload to carry anything else.
        #expect(ContextCompaction.durationMs(grok) == nil)
        #expect(ContextCompaction.trigger(grok) == nil)
    }

    @Test("bare markers carry no figures")
    func bareMarkersCarryNoFigures() {
        let bare = Self.meta(#"{"contextCompaction":{"version":1}}"#)
        #expect(ContextCompaction.tokens(bare).before == nil)
        #expect(ContextCompaction.tokens(bare).after == nil)
        #expect(ContextCompaction.durationMs(bare) == nil)
        // A string or negative count is not a count.
        let odd = Self.meta(#"{"contextCompaction":{"version":1,"preTokens":"100","postTokens":-1,"durationMs":"3"}}"#)
        #expect(ContextCompaction.tokens(odd).before == nil)
        #expect(ContextCompaction.tokens(odd).after == nil)
        #expect(ContextCompaction.durationMs(odd) == nil)
    }

    // MARK: - summary

    private static let claimed = #"{"contextCompaction":{"version":1},"codeg.compactionSummary":true}"#

    @Test("returns the output of a call the backend claimed")
    func returnsTheOutputOfAClaimedCall() {
        #expect(ContextCompaction.summary(Self.meta(Self.claimed), output: "We refactored the parser.")
                == "We refactored the parser.")
    }

    @Test("ignores output the backend did not claim as a summary")
    func ignoresUnclaimedOutput() {
        // claude's LEGACY call parks its metadata object on the same channel.
        #expect(ContextCompaction.summary(Self.meta(#"{"contextCompaction":{"version":1}}"#),
                                          output: #"{"trigger":"manual","preTokens":191322}"#) == nil)
        // The grok bridge's boolean marker never carries one either.
        #expect(ContextCompaction.summary(Self.meta(#"{"contextCompaction":true}"#), output: "text") == nil)
    }

    @Test("requires the claim on a compaction call, and a non-blank output")
    func requiresTheClaimAndANonBlankOutput() {
        #expect(ContextCompaction.summary(Self.meta(#"{"codeg.compactionSummary":true}"#), output: "x") == nil)
        #expect(ContextCompaction.summary(
            Self.meta(#"{"contextCompaction":{"version":1},"codeg.compactionSummary":"true"}"#), output: "x") == nil)
        #expect(ContextCompaction.summary(Self.meta(Self.claimed), output: nil) == nil)
        #expect(ContextCompaction.summary(Self.meta(Self.claimed), output: "  \n ") == nil)
    }

    // MARK: - info / failure

    @Test("an error in the payload fails the compaction, whatever its lifecycle")
    func anErrorInThePayloadFailsIt() {
        let info = ContextCompaction.info(
            meta: Self.meta(#"{"contextCompaction":{"version":1,"error":"compaction interrupted"}}"#),
            output: nil, running: false, failed: false)
        #expect(info.failed)
        #expect(info.error == "compaction interrupted")
        // A blank error is no error.
        let blank = ContextCompaction.info(meta: Self.meta(#"{"contextCompaction":{"version":1,"error":"  "}}"#),
                                           output: nil, running: false, failed: false)
        #expect(!blank.failed)
        #expect(blank.error == nil)
    }

    @Test("a failed lifecycle fails the compaction without a payload error")
    func aFailedLifecycleFailsIt() {
        let info = ContextCompaction.info(meta: Self.meta(#"{"contextCompaction":{"version":1}}"#),
                                          output: nil, running: false, failed: true)
        #expect(info.failed)
        #expect(info.error == nil)
    }

    // MARK: - identity (Android 52f2021, web `compactionEventKey`)

    @Test("names a compaction event by all three of its figures, or not at all")
    func namesACompactionEventByItsFigures() {
        let versioned = Self.meta(
            #"{"contextCompaction":{"version":1,"trigger":"auto","preTokens":180000,"postTokens":22000,"durationMs":5300}}"#)
        #expect(ContextCompaction.eventKey(versioned) == "compaction:180000:22000:5300")
        // codex's bare marker names no event: two of them must not fold into one.
        #expect(ContextCompaction.eventKey(Self.meta(#"{"contextCompaction":{"version":1}}"#)) == nil)
        #expect(ContextCompaction.eventKey(Self.meta(#"{"contextCompaction":{"version":1,"preTokens":9,"postTokens":4}}"#)) == nil)
        // The boolean marker has no payload; grok's top-level counts alone name nothing.
        #expect(ContextCompaction.eventKey(Self.meta(#"{"contextCompaction":true,"tokensBefore":9,"tokensAfter":4}"#)) == nil)
        #expect(ContextCompaction.eventKey(Self.meta(#"{"preTokens":9,"postTokens":4,"durationMs":70}"#)) == nil)
    }

    @Test("a compaction carries its call's id and its event key, live and in history")
    func aCompactionCarriesItsCallIDAndEventKey() {
        let failed = ContextCompaction.info(
            meta: Self.meta(#"{"contextCompaction":{"version":1,"error":"context too small"}}"#),
            output: nil, running: false, failed: false, callID: "c1")
        #expect(failed.failed)
        #expect(failed.callID == "c1")
        #expect(failed.eventKey == nil)

        let meta = Self.meta(#"{"contextCompaction":{"version":1,"preTokens":9,"postTokens":4,"durationMs":70}}"#)
        let turn = MessageTurn(id: "cmp", role: .assistant, blocks: [
            .toolUse(id: "cmp-1", name: "context_compaction", inputPreview: nil, status: .unknown, meta: meta),
            .toolResult(id: "cmp-1", outputPreview: "", isError: false, agentStats: nil),
        ], timestamp: Date())
        guard case .compaction(let persisted)? = MessageRender.adaptTurn(turn).first else {
            Issue.record("expected a compaction part"); return
        }
        #expect(persisted.callID == "cmp-1")
        #expect(persisted.eventKey == "compaction:9:4:70")

        let live = LiveTurn()
        live.upsertToolCall(id: "compacting-status", title: "Compacting", kind: "", status: "completed",
                            rawInput: nil, rawOutput: nil, content: nil, meta: meta)
        guard case .compaction(let streamed)? = MessageRender.adaptLive(live).first else {
            Issue.record("expected a compaction part"); return
        }
        #expect(streamed.callID == "compacting-status")
        #expect(streamed.eventKey == persisted.eventKey)
    }

    // MARK: - display helpers

    @Test("formats the duration as the web does")
    func formatsTheDuration() {
        #expect(ContextCompaction.formatDuration(3200) == "3.2s")
        #expect(ContextCompaction.formatDuration(1500) == "1.5s")
        #expect(ContextCompaction.formatDuration(45_000) == "45s")
        #expect(ContextCompaction.formatDuration(41_600) == "42s")
        #expect(ContextCompaction.formatDuration(0) == nil)
        #expect(ContextCompaction.formatDuration(nil) == nil)
    }

    @Test("names the known triggers, both spellings of automatic, and passes others through")
    func namesTheKnownTriggers() {
        #expect(ContextCompaction.Trigger("automatic") == .automatic)
        #expect(ContextCompaction.Trigger("auto") == .automatic)
        #expect(ContextCompaction.Trigger("Manual") == .manual)
        #expect(ContextCompaction.Trigger("idle") == .idle)
        #expect(ContextCompaction.Trigger("threshold") == .other("threshold"))
    }

    // MARK: - adapters

    @Test("a history divider in the versioned shape is a compaction, with its figures and summary")
    func aHistoryDividerInTheVersionedShape() {
        // What codeg's claude parser writes for a `compact_boundary` record,
        // with the continuation summary folded in.
        let meta = Self.meta(
            #"{"contextCompaction":{"version":1,"trigger":"automatic","preTokens":191322,"postTokens":12034,"durationMs":41000},"codeg.compactionSummary":true}"#)
        let turn = MessageTurn(id: "cmp-history", role: .assistant, blocks: [
            .toolUse(id: "cmp-history-1", name: "context_compaction", inputPreview: nil, status: .unknown, meta: meta),
            .toolResult(id: "cmp-history-1", outputPreview: "We kept the plan.", isError: false, agentStats: nil),
        ], timestamp: Date())
        let parts = MessageRender.adaptTurn(turn)
        guard parts.count == 1, case .compaction(let info) = parts[0] else {
            Issue.record("expected a single compaction part, got \(parts.count) parts"); return
        }
        #expect(info == CompactionInfo(before: 191322, after: 12034, running: false, failed: false,
                                       durationMs: 41000, error: nil, trigger: "automatic",
                                       summary: "We kept the plan.", callID: "cmp-history-1",
                                       eventKey: "compaction:191322:12034:41000"))
    }

    @Test("a live compaction streams its summary and fails in place")
    func aLiveCompactionStreamsItsSummaryAndFails() {
        let live = LiveTurn()
        let meta = Self.meta(Self.claimed)
        live.updateToolCall(id: "cmp-live-1", title: "Compact conversation", status: "in_progress",
                            rawInput: nil, rawOutput: "We kept", content: nil, append: true, meta: meta)
        guard case .compaction(let running)? = MessageRender.adaptLive(live).first else {
            Issue.record("expected a compaction part"); return
        }
        #expect(running.running)
        #expect(!running.failed)
        #expect(running.summary == "We kept")

        live.updateToolCall(id: "cmp-live-1", title: nil, status: "failed", rawInput: nil,
                            rawOutput: nil, content: nil, append: false, meta: nil)
        guard case .compaction(let failed)? = MessageRender.adaptLive(live).first else {
            Issue.record("expected a compaction part"); return
        }
        #expect(!failed.running)
        #expect(failed.failed)
    }
}
