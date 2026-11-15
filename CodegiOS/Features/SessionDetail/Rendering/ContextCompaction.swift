import Foundation

/// Context-compaction tool-call detection (port of the web `lib/context-compaction.ts`,
/// codeg 0.44).
///
/// A compaction lifecycle arrives as an ACP `tool_call` whose
/// `_meta.contextCompaction` takes one of two shapes, both accepted long-term:
///
/// - the boolean marker `true` — codex-acp 1.1.3–1.2.x and codeg's Grok bridge
///   (`auto_compact_completed`, live and in history), which stamps top-level
///   `tokensBefore` / `tokensAfter` counts next to it;
/// - the versioned object `{version: 1, …}` — codex-acp 1.3.0+ (a bare
///   `{version: 1}`), deepseek-acp and claude-agent-acp 0.75.0+, whose schema
///   reserves optional `trigger`, `preTokens`, `postTokens`, `durationMs` and
///   `error` fields. codeg's history parsers (claude, codex, deepseek) write
///   this shape too, so a reopened conversation draws the same divider.
///
/// It is addressed by that meta key, NOT by tool name or agent, so an adapter
/// that adopts the convention lights the divider up with no wiring. It renders
/// as a chrome-less centered divider ("context was compacted here"), not as a
/// tool card, and must never fold into a "N tools" group.
enum ContextCompaction {
    /// The `_meta` key with which the server claims a compaction call's output
    /// IS its retained summary (web `COMPACTION_SUMMARY_META_KEY`, Rust
    /// `parsers::COMPACTION_SUMMARY_META_KEY`). Stamped by the live reader of
    /// the ACP compaction lifecycle and by the history parsers that recover the
    /// summary from the transcript.
    static let summaryMetaKey = "codeg.compactionSummary"

    /// Whether this tool call's `_meta` marks it as a compaction: the boolean
    /// `true` (a string `"true"` does not count), or an object whose `version`
    /// is an integer ≥ 1 (not `"1"`, not `1.5`) — later versions keep matching.
    static func matches(_ meta: AnyJSON?) -> Bool {
        switch meta?["contextCompaction"] {
        case .bool(true)?:
            return true
        case .object(let marker)?:
            guard let version = marker["version"]?.double else { return false }
            return version.isFinite && version >= 1 && version.rounded(.towardZero) == version
        default:
            return false
        }
    }

    /// The versioned marker's payload, or nil for the boolean shape and for
    /// non-compaction meta. Every field in it may be absent — read leniently.
    static func payload(_ meta: AnyJSON?) -> AnyJSON? {
        guard matches(meta), let marker = meta?["contextCompaction"], marker.object != nil else { return nil }
        return marker
    }

    /// The token counts either side of the boundary: Grok's top-level
    /// `tokensBefore` / `tokensAfter`, else the versioned payload's
    /// `preTokens` / `postTokens`. Often absent (codex sends none) — the
    /// divider falls back to a plain label then.
    static func tokens(_ meta: AnyJSON?) -> (before: Int?, after: Int?) {
        let payload = Self.payload(meta)
        return (count(meta, "tokensBefore") ?? count(payload, "preTokens"),
                count(meta, "tokensAfter") ?? count(payload, "postTokens"))
    }

    /// How long the compaction took, when the payload says.
    static func durationMs(_ meta: AnyJSON?) -> Int? { count(payload(meta), "durationMs") }

    /// The adapter's own account of a compaction that failed — a non-blank
    /// string in the payload.
    static func error(_ meta: AnyJSON?) -> String? { text(payload(meta), "error") }

    /// Why it ran (`manual`, `automatic` / `auto`, `idle`, or an adapter's own
    /// word), when the payload says.
    static func trigger(_ meta: AnyJSON?) -> String? { text(payload(meta), "trigger") }

    /// The retained summary a compaction call carries, or nil. Only on the
    /// server's explicit claim (`summaryMetaKey: true`): the LEGACY compaction
    /// call puts other things on the same channel (claude parks its
    /// `{trigger, preTokens, …}` metadata object there), and a history divider
    /// whose transcript kept no summary has none to claim.
    static func summary(_ meta: AnyJSON?, output: String?) -> String? {
        guard matches(meta), meta?[summaryMetaKey]?.bool == true,
              let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return output
    }

    /// Identity of a compaction EVENT, or nil when the payload cannot name one
    /// (web `compactionEventKey`): the token counts either side of the boundary
    /// plus the time it took, in milliseconds. All three are required, and
    /// that is the point: codex-acp sends a bare `{version: 1}` for every
    /// compaction it performs, so a looser key would fold a session's separate
    /// compactions into one — while two real compactions agreeing on all three
    /// does not happen.
    static func eventKey(_ meta: AnyJSON?) -> String? {
        let payload = Self.payload(meta)
        guard let pre = count(payload, "preTokens"), let post = count(payload, "postTokens"),
              let duration = count(payload, "durationMs") else { return nil }
        return "compaction:\(pre):\(post):\(duration)"
    }

    /// A compaction call → what its divider draws. `failed`: the call's own
    /// lifecycle failed (web `output-error`); an `error` in the payload fails
    /// it as well. `callID`: the call's own id — the event's name wherever the
    /// live stream and the transcript agree on one (``CompactionInfo/callID``).
    static func info(meta: AnyJSON?, output: String?, running: Bool, failed: Bool,
                     callID: String? = nil) -> CompactionInfo {
        let counts = Self.tokens(meta)
        let error = Self.error(meta)
        return CompactionInfo(before: counts.before, after: counts.after, running: running,
                              failed: failed || error != nil, durationMs: durationMs(meta),
                              error: error, trigger: trigger(meta),
                              summary: summary(meta, output: output),
                              callID: callID, eventKey: eventKey(meta))
    }

    /// `durationMs` as a compact label — `3.2s`, or `45s` from ten seconds
    /// on — or nil when there is no positive duration (web `formatDuration`).
    static func formatDuration(_ durationMs: Int?) -> String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let seconds = Double(durationMs) / 1000
        return seconds >= 10 ? "\(Int(seconds.rounded()))s" : String(format: "%.1fs", seconds)
    }

    /// The triggers adapters send, by what the divider calls them. Not
    /// exhaustive on purpose: `trigger` is adapter-defined vocabulary, and an
    /// unknown value is shown verbatim rather than dropped or mislabelled.
    /// Automatic has two spellings in the wild — claude renames the SDK's
    /// `auto` to `automatic` on the wire (and codeg's claude parser mirrors it
    /// for history), deepseek's parser passes `auto` through.
    enum Trigger: Equatable {
        case manual, automatic, idle
        case other(String)

        init(_ raw: String) {
            switch raw.lowercased() {
            case "manual": self = .manual
            case "auto", "automatic": self = .automatic
            case "idle": self = .idle
            default: self = .other(raw)
            }
        }
    }

    /// A non-negative, finite number field off the opaque meta pass-through,
    /// as an integer.
    private static func count(_ source: AnyJSON?, _ key: String) -> Int? {
        guard let value = source?[key]?.double, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }

    /// A non-blank string field, as sent.
    private static func text(_ source: AnyJSON?, _ key: String) -> String? {
        guard let value = source?[key]?.string,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// One compaction as its divider draws it (web `ContextCompactionCard`'s props,
/// resolved): the counts and duration of the versioned payload or Grok's
/// top-level counts, its lifecycle, and a summary the server claimed for it.
struct CompactionInfo: Equatable, Sendable {
    var before: Int?
    var after: Int?
    var running: Bool
    /// The call failed, or its payload carries an `error`.
    var failed: Bool = false
    var durationMs: Int?
    /// The adapter's error text, for the accessibility hint / pointer tooltip.
    var error: String?
    var trigger: String?
    /// The retained summary (``ContextCompaction/summary(_:output:)``). May
    /// still be streaming in while `running`.
    var summary: String?
    /// The compaction call's id. One compaction reaches the thread twice — the
    /// live call, and the transcript's divider — and codex names both by the
    /// same id (its live `compactionId` is the item id its parser names the
    /// divider by), which is how the two are drawn once
    /// (`TranscriptTimeline.dedupeCompactions`).
    var callID: String?
    /// ``ContextCompaction/eventKey(_:)``: the event's identity by its figures,
    /// where the two copies name it differently (claude's live id is its
    /// `compacting` status message, its transcript's the boundary record).
    var eventKey: String?
}
