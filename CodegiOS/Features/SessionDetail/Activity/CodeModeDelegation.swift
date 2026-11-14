import Foundation

/// opencode code-mode delegation — port of the code-mode half of the web's
/// `src/lib/delegation-card.ts` (codeg 0.44: `codeModeCallSite` …
/// `isCodeModeDelegationCall`).
///
/// OpenCode 2.x runs MCP tools through its built-in `execute` tool: the model
/// writes `tools["codeg-mcp"].delegate_to_agent({…})` as JavaScript packed into
/// a `{code: "…"}` input. This recognises such a payload and reads the
/// arguments back out of the JS source with the web's scanner — which is the
/// backend's (`acp/lifecycle.rs`, `code_mode_call_span` and friends), so the
/// call is drawn as a delegation exactly when the backend registers one.
///
/// The scanner is STRICT: `tools` must reach `delegate_to_agent(` through a
/// real accessor, strings / templates / comments are skipped (a task that
/// QUOTES a call is no call), and every ambiguity reads as "unreadable" rather
/// than a guessed value — spread / computed-key / escaped-quoted-key syntax
/// screens the whole argument object out, values must end where their
/// property ends, quoted keys match only escape-free at brace depth 1, and a
/// template's text is read as the runtime cooks it.
///
/// JavaScript semantics, mirrored explicitly: the source is scanned in UTF-16
/// code units (JS string indices and `charCodeAt`); an index past either end
/// reads as `undefined` (nil here, equal to nothing); the size cap counts
/// UTF-8 bytes the way the web estimates them from UTF-16 units; and template
/// text is cooked unit by unit (escapes decoded, bare CR / CRLF normalized to
/// LF, U+2028 / U+2029 kept verbatim).
enum CodeModeDelegation {
    /// The arguments read out of the call, each nil when absent or
    /// unreadable. Raw values: the caller narrows the agent slug and the
    /// assistant id (`DelegationModel.parseInput`), as the web's
    /// `parseCodeModeInput` does with `coerceAgentType` / `coerceAssistantId`.
    struct Args: Equatable {
        var agentType: String?
        var assistantId: String?
        var task: String?
        var workingDir: String?
    }

    // MARK: - Entry points

    /// Whether a raw tool input is an opencode code-mode `execute` payload
    /// whose `code` source announces a `delegate_to_agent` call. Shape only —
    /// classify a tool call with
    /// ``isCodeModeDelegationCall(normalizedToolName:input:)``, which also
    /// checks the tool.
    static func isCodeModeDelegationInput(_ raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        // Cheap pre-gate, same as the backend's: a JSON payload carrying a
        // `code` key contains the literal `"code"` units. (A code-unit search,
        // like JS `includes`, not Swift's grapheme-aware `contains`.)
        guard (raw as NSString).range(of: #""code""#, options: .literal).location != NSNotFound else {
            return false
        }
        return callOf(ActivityJSON.tryParse(raw)) != nil
    }

    /// Whether a tool call is opencode's code-mode `execute` running a
    /// `delegate_to_agent` call. Takes the NORMALIZED tool name: `execute`
    /// normalizes to `bash`, live and in history. The tool gate keeps another
    /// tool's `code` argument — a Playwright `browser_run_code` script that
    /// mocks the call, say — from passing as one.
    static func isCodeModeDelegationCall(normalizedToolName: String, input: String?) -> Bool {
        normalizedToolName == "bash" && isCodeModeDelegationInput(input)
    }

    /// The arguments of a code-mode delegation payload (web
    /// `parseCodeModeInput`, on `JSON.parse(raw)`); nil when the payload is no
    /// code-mode delegation call at all.
    ///
    /// The argument must be exactly one object literal, and its region must
    /// hold no syntax the scanner cannot evaluate (spread, computed keys,
    /// escaped quoted keys, conditionals, calls, shorthand argument keys …):
    /// any of those could hide an `assistant_id` or change a value, so every
    /// field reads as unknown (an all-nil ``Args``). Otherwise each readable
    /// value is returned and each unreadable one (interpolation, an escape
    /// outside the minimal set) stays nil.
    static func parseArgs(_ raw: String?) -> Args? {
        guard let raw, !raw.isEmpty else { return nil }
        return parseArgs(parsed: ActivityJSON.tryParse(raw))
    }

    static func parseArgs(parsed: [String: Any]?) -> Args? {
        guard let call = callOf(parsed) else { return nil }
        let s = call.source
        let open = call.site.open, close = call.site.close
        let start = open + 1
        guard call.site.readable,
              singleObjectArgument(s, open: open, close: close),
              argsTransparent(s, start, close)
        else { return Args() }
        let assistantAt = findKey(s, start, close, Word.assistantId)
        let agentAt = findKey(s, start, close, Word.agentType)
        let workingAt = findKey(s, start, close, Word.workingDir)
        let taskAt = findKey(s, start, close, Word.task)
        return Args(
            agentType: agentAt.flatMap { objectStringValue(s, $0) },
            assistantId: assistantAt.flatMap { assistantIdValue(s, $0) },
            task: taskAt.flatMap { objectTaskValue(s, $0) },
            workingDir: workingAt.flatMap { objectStringValue(s, $0) }
        )
    }

    // MARK: - Source

    /// Scan cap in UTF-8 bytes, the unit the backend measures (`code.len()`).
    private static let maxCodeBytes = 1 << 20
    private static let maxTemplateFrames = 16

    /// The script as JavaScript sees it: UTF-16 code units.
    private struct Source {
        let u: [UInt16]

        init(_ code: String) { u = Array(code.utf16) }

        var count: Int { u.count }

        /// `code[i]`: nil (JS `undefined`) past either end.
        subscript(_ i: Int) -> UInt16? { i >= 0 && i < u.count ? u[i] : nil }

        /// `code.slice(from, to)`.
        func slice(_ from: Int, _ to: Int) -> ArraySlice<UInt16> {
            let a = min(max(from, 0), u.count)
            let b = min(max(to, a), u.count)
            return u[a..<b]
        }

        /// `code.indexOf(needle, from)`; nil for -1.
        func indexOf(_ needle: [UInt16], from: Int) -> Int? {
            var i = max(from, 0)
            while i + needle.count <= u.count {
                var k = 0
                while k < needle.count, u[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
                i += 1
            }
            return nil
        }

        /// `code.slice(from, to).includes("${")`.
        func hasInterpolation(_ from: Int, _ to: Int) -> Bool {
            let end = min(to, u.count)
            var k = max(from, 0)
            while k + 1 < end {
                if u[k] == U.dollar, u[k + 1] == U.lbrace { return true }
                k += 1
            }
            return false
        }
    }

    /// The code units the scanner compares against.
    private enum U {
        static let tab: UInt16 = 0x09
        static let lf: UInt16 = 0x0A
        static let ff: UInt16 = 0x0C
        static let cr: UInt16 = 0x0D
        static let space: UInt16 = 0x20
        static let quote: UInt16 = 0x22       // "
        static let dollar: UInt16 = 0x24      // $
        static let amp: UInt16 = 0x26         // &
        static let apos: UInt16 = 0x27        // '
        static let lparen: UInt16 = 0x28      // (
        static let rparen: UInt16 = 0x29      // )
        static let star: UInt16 = 0x2A        // *
        static let comma: UInt16 = 0x2C       // ,
        static let dot: UInt16 = 0x2E         // .
        static let slash: UInt16 = 0x2F       // /
        static let zero: UInt16 = 0x30        // 0
        static let nine: UInt16 = 0x39        // 9
        static let colon: UInt16 = 0x3A       // :
        static let equals: UInt16 = 0x3D      // =
        static let gt: UInt16 = 0x3E          // >
        static let question: UInt16 = 0x3F    // ?
        static let lbracket: UInt16 = 0x5B    // [
        static let backslash: UInt16 = 0x5C   // \
        static let rbracket: UInt16 = 0x5D    // ]
        static let backtick: UInt16 = 0x60    // `
        static let lbrace: UInt16 = 0x7B      // {
        static let pipe: UInt16 = 0x7C        // |
        static let rbrace: UInt16 = 0x7D      // }
        static let lineSeparator: UInt16 = 0x2028
        static let paragraphSeparator: UInt16 = 0x2029
    }

    private enum Word {
        static let tools = Array("tools".utf16)
        static let delegate = Array("delegate_to_agent".utf16)
        static let agentType = Array("agent_type".utf16)
        static let task = Array("task".utf16)
        static let workingDir = Array("working_dir".utf16)
        static let assistantId = Array("assistant_id".utf16)
        static let commentClose = Array("*/".utf16)
        static let rbrace = [U.rbrace]
    }

    /// Keywords that make what follows them conditional, repeated or
    /// deferred; `function` defers its body and its parameter defaults alike.
    /// Mirrors `CODE_MODE_BRANCH_KEYWORDS` in `acp/lifecycle.rs`.
    private static let branchKeywords: [[UInt16]] =
        ["if", "else", "switch", "for", "while", "do", "catch", "yield", "function"].map { Array($0.utf16) }

    /// The argument keys the scanner reads; a bare one not followed by `:` is
    /// a SHORTHAND property (or a variable in value position) — either way its
    /// value is a runtime value, and a shorthand after an explicit spelling
    /// overrides it.
    private static let argKeys: [[UInt16]] = [Word.agentType, Word.task, Word.workingDir, Word.assistantId]

    // MARK: - Lexing

    /// Any non-ASCII unit counts as an identifier unit: the scan only needs
    /// the boundaries of ASCII words, and over-approximating Unicode as
    /// identifier units can only reject, never mis-split, a boundary. Matches
    /// `is_js_ident_byte` (>= 0x80).
    private static func isIdentUnit(_ s: Source, _ at: Int) -> Bool {
        guard let c = s[at] else { return false }
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, U.dollar: return true   // 0-9 A-Z a-z _ $
        default: return c >= 0x80
        }
    }

    private static func isWordAt(_ s: Source, _ at: Int, _ word: [UInt16]) -> Bool {
        if at < 0 || at + word.count > s.count { return false }
        for k in word.indices where s.u[at + k] != word[k] { return false }
        let after = at + word.count
        return (at == 0 || !isIdentUnit(s, at - 1)) && (after >= s.count || !isIdentUnit(s, after))
    }

    private static func identEnd(_ s: Source, _ at: Int) -> Int {
        var end = at
        while isIdentUnit(s, end) { end += 1 }
        return end
    }

    /// Rust's `u8::is_ascii_whitespace`: space, \t, \n, \f, \r (not \v).
    private static func isWhitespace(_ c: UInt16?) -> Bool {
        guard let c else { return false }
        switch c {
        case U.space, U.tab, U.lf, U.ff, U.cr: return true
        default: return false
        }
    }

    /// JS LineTerminator: LF, CR, U+2028, U+2029 — a line comment ends at any
    /// of these, not just LF.
    private static func isLineTerminator(_ c: UInt16?) -> Bool {
        guard let c else { return false }
        switch c {
        case U.lf, U.cr, U.lineSeparator, U.paragraphSeparator: return true
        default: return false
        }
    }

    /// Past the `'…'` / `"…"` string opening at `open`.
    private static func skipString(_ s: Source, _ open: Int) -> Int? {
        let quote = s[open]
        var i = open + 1
        while i < s.count {
            if s.u[i] == U.backslash {
                i += 2
                continue
            }
            if s.u[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }

    private enum TemplateFrame {
        case content
        case interp(braceDepth: Int)
    }

    /// Past the template literal opening at `open`, through any `${…}` and the
    /// templates nested in it.
    private static func skipTemplate(_ s: Source, _ open: Int) -> Int? {
        var stack: [TemplateFrame] = [.content]
        var i = open + 1
        while !stack.isEmpty {
            if stack.count > maxTemplateFrames { return nil }
            if i >= s.count { return nil }
            let c = s.u[i]
            switch stack[stack.count - 1] {
            case .content:
                if c == U.backtick {
                    stack.removeLast()
                    i += 1
                    if stack.isEmpty { return i }
                } else if c == U.backslash {
                    i += 2
                } else if c == U.dollar, s[i + 1] == U.lbrace {
                    stack.append(.interp(braceDepth: 0))
                    i += 2
                } else {
                    i += 1
                }
            case .interp(let depth):
                if c == U.lbrace {
                    stack[stack.count - 1] = .interp(braceDepth: depth + 1)
                    i += 1
                } else if c == U.rbrace {
                    if depth == 0 {
                        stack.removeLast()
                    } else {
                        stack[stack.count - 1] = .interp(braceDepth: depth - 1)
                    }
                    i += 1
                } else if c == U.apos || c == U.quote {
                    guard let end = skipString(s, i) else { return nil }
                    i = end
                } else if c == U.backtick {
                    stack.append(.content)
                    i += 1
                } else if c == U.slash, s[i + 1] == U.slash {
                    while i < s.count, !isLineTerminator(s.u[i]) { i += 1 }
                } else if c == U.slash, s[i + 1] == U.star {
                    guard let close = s.indexOf(Word.commentClose, from: i + 2) else { return nil }
                    i = close + 2
                } else {
                    i += 1
                }
            }
        }
        return nil
    }

    private static func skipWhitespaceAndComments(_ s: Source, _ from: Int) -> Int {
        var i = from
        while true {
            if isWhitespace(s[i]) {
                i += 1
                continue
            }
            if s[i] == U.slash, s[i + 1] == U.slash {
                i += 2
                while i < s.count, !isLineTerminator(s.u[i]) { i += 1 }
                continue
            }
            if s[i] == U.slash, s[i + 1] == U.star {
                guard let close = s.indexOf(Word.commentClose, from: i + 2) else { return s.count }
                i = close + 2
                continue
            }
            return i
        }
    }

    /// A `/` opening a comment at `i`.
    private static func opensComment(_ s: Source, _ i: Int) -> Bool {
        s[i] == U.slash && (s[i + 1] == U.slash || s[i + 1] == U.star)
    }

    /// Whether `units` is longer than `cap` UTF-8 bytes, counted the way the
    /// web counts them from UTF-16 without encoding: a unit is 1–3 bytes (a
    /// surrogate half is 2, so a pair is 4).
    private static func utf8LengthExceeds(_ units: [UInt16], _ cap: Int) -> Bool {
        if units.count > cap { return true }
        if units.count * 3 <= cap { return false }
        var bytes = 0
        for c in units {
            if c < 0x80 {
                bytes += 1
            } else if c < 0x800 || (0xD800...0xDFFF).contains(c) {
                bytes += 2
            } else {
                bytes += 3
            }
            if bytes > cap { return true }
        }
        return false
    }

    // MARK: - The call site

    private struct CallSite {
        /// The call's `(` and its matching `)`.
        let open: Int
        let close: Int
        /// Its arguments may be read as the delegation's.
        let readable: Bool
    }

    /// The `code` source and its first call site for a recognized code-mode
    /// delegation payload (web `codeModeCallOf`, the frontend mirror of the
    /// backend's `code_mode_delegation_code`).
    private static func callOf(_ parsed: [String: Any]?) -> (source: Source, site: CallSite)? {
        guard let code = parsed?["code"] as? String else { return nil }
        let source = Source(code)
        guard let site = callSite(source) else { return nil }
        return (source, site)
    }

    /// The first `delegate_to_agent(` call reached via a `tools` accessor: its
    /// argument list, and whether those arguments may be read as the
    /// delegation's — it is the only call site in a scan that reached the end
    /// of the script, or it provably runs before any other (at brace depth 0,
    /// outside any parameter list or destructuring pattern, with nothing
    /// before it that branches, defers or hides code in a `${…}`). Nil past
    /// the scan cap, on unbalanced input before the call, with no such call,
    /// or when a `/` that is no comment precedes the call: a regex literal is
    /// indistinguishable from division here, and its body can carry the quote
    /// or backtick that desynchronizes everything after it.
    private static func callSite(_ s: Source) -> CallSite? {
        if utf8LengthExceeds(s.u, maxCodeBytes) { return nil }
        var i = 0
        var depth = 0
        // The `(` / `[` groups open at `i` (only their number matters).
        var groups = 0
        var branched = false
        var first: (open: Int, close: Int)?
        var runsFirst = false
        // How many groups enclosing the first site have yet to close; each
        // must close as a call, a grouping or an array — not as an arrow's
        // parameter list or a destructuring pattern, whose defaults run only
        // when a value is missing.
        var enclosing = 0
        var sites = 0
        var counted = true
        scan: while i < s.count {
            let c = s.u[i]
            if c == U.apos || c == U.quote || c == U.backtick {
                guard let end = (c == U.backtick ? skipTemplate(s, i) : skipString(s, i)) else {
                    if first == nil { return nil }
                    counted = false
                    break scan
                }
                // A `${…}` runs code the scan skips: a call in it is one the
                // count cannot see, and before the first site it may run first.
                if c == U.backtick, s.hasInterpolation(i, end) {
                    counted = false
                    if first == nil { branched = true }
                }
                i = end
            } else if opensComment(s, i) {
                i = skipWhitespaceAndComments(s, i)
            } else if c == U.slash {
                if first == nil { return nil }
                counted = false
                break scan
            } else if c == U.lbrace {
                depth += 1
                i += 1
            } else if c == U.rbrace {
                depth -= 1
                i += 1
            } else if c == U.lparen || c == U.lbracket {
                groups += 1
                i += 1
            } else if c == U.rparen || c == U.rbracket {
                groups = max(groups - 1, 0)   // JS `pop()` on an empty array
                i += 1
                if enclosing > groups {
                    enclosing = groups
                    let next = skipWhitespaceAndComments(s, i)
                    let parameters = c == U.rparen && s[next] == U.equals && s[next + 1] == U.gt
                    let pattern = c == U.rbracket && s[next] == U.equals
                        && s[next + 1] != U.equals && s[next + 1] != U.gt
                    if parameters || pattern { runsFirst = false }
                }
            } else if c == U.question {
                branched = true
                i += 1
            } else if c == U.amp || c == U.pipe, s[i + 1] == c {
                branched = true
                i += 2
            } else if c == U.equals, s[i + 1] == U.gt {
                branched = true
                i += 2
            } else {
                for keyword in branchKeywords where isWordAt(s, i, keyword) {
                    branched = true
                    i += 1
                    continue scan
                }
                if isWordAt(s, i, Word.tools), let open = toolsCallOpen(s, i) {
                    guard let close = matchingClose(s, open, U.lparen, U.rparen) else {
                        if first == nil { return nil }
                        counted = false
                        break scan
                    }
                    sites += 1
                    if first == nil {
                        first = (open, close)
                        runsFirst = depth == 0 && !branched
                        enclosing = groups
                    }
                    i = close + 1
                    continue scan
                }
                i += 1
            }
        }
        guard let first else { return nil }
        // A group around the first site that never closed in the scan could
        // still be a parameter list or a pattern.
        let provable = runsFirst && enclosing == 0
        return CallSite(open: first.open, close: first.close, readable: provable || (sites == 1 && counted))
    }

    /// The `(` of `tools.<server>.delegate_to_agent(` /
    /// `tools["<server>"].delegate_to_agent(` starting at `toolsAt`.
    private static func toolsCallOpen(_ s: Source, _ toolsAt: Int) -> Int? {
        var i = skipWhitespaceAndComments(s, toolsAt + Word.tools.count)
        let c = s[i]
        if c == U.lbracket {
            i = skipWhitespaceAndComments(s, i + 1)
            let quote = s[i]
            guard quote == U.apos || quote == U.quote, let end = skipString(s, i) else { return nil }
            if end == i + 2 { return nil }   // an empty server name
            i = skipWhitespaceAndComments(s, end)
            guard s[i] == U.rbracket else { return nil }
            i = skipWhitespaceAndComments(s, i + 1)
            guard s[i] == U.dot else { return nil }
            i = skipWhitespaceAndComments(s, i + 1)
        } else if c == U.dot {
            i = skipWhitespaceAndComments(s, i + 1)
            let end = identEnd(s, i)
            if end == i { return nil }
            i = skipWhitespaceAndComments(s, end)
            guard s[i] == U.dot else { return nil }
            i = skipWhitespaceAndComments(s, i + 1)
        } else {
            return nil
        }
        guard isWordAt(s, i, Word.delegate) else { return nil }
        i = skipWhitespaceAndComments(s, i + Word.delegate.count)
        return s[i] == U.lparen ? i : nil
    }

    /// Offset of the `closeCh` matching the `openCh` at `open`, skipping
    /// strings, templates and comments. Mirrors `matching_close` in
    /// `acp/lifecycle.rs`.
    private static func matchingClose(_ s: Source, _ open: Int, _ openCh: UInt16, _ closeCh: UInt16) -> Int? {
        var depth = 0
        var i = open
        while i < s.count {
            let c = s.u[i]
            if c == U.apos || c == U.quote {
                guard let end = skipString(s, i) else { return nil }
                i = end
            } else if c == U.backtick {
                guard let end = skipTemplate(s, i) else { return nil }
                i = end
            } else if opensComment(s, i) {
                i = skipWhitespaceAndComments(s, i)
            } else if c == openCh {
                depth += 1
                i += 1
            } else if c == closeCh {
                depth -= 1
                if depth == 0 { return i }
                i += 1
            } else {
                i += 1
            }
        }
        return nil
    }

    // MARK: - The arguments

    /// Whether the call's argument list `(open, close)` holds exactly ONE
    /// object literal (a trailing comma aside). Any other shape —
    /// `c ? {…} : {…}`, `x || {…}`, `{…}.y`, a variable — passes something the
    /// literal alone does not determine.
    private static func singleObjectArgument(_ s: Source, open: Int, close: Int) -> Bool {
        let start = skipWhitespaceAndComments(s, open + 1)
        guard s[start] == U.lbrace, let objectClose = matchingClose(s, start, U.lbrace, U.rbrace) else {
            return false
        }
        var after = skipWhitespaceAndComments(s, objectClose + 1)
        if s[after] == U.comma { after = skipWhitespaceAndComments(s, after + 1) }
        return after == close
    }

    /// Conservative pre-pass over the argument region: false when it holds
    /// syntax whose effect the scanner cannot evaluate — spread (`...base`
    /// may carry an `assistant_id`), a `[` (computed keys, array values), a
    /// quoted KEY with a backslash (an unknowable spelling), a `(` / `)` or a
    /// non-comment `/` (calls, grouping, division, regex), a `?` (ternary,
    /// optional chain, `??`), a `\` outside a string (a Unicode-escaped
    /// identifier: `task` IS `task`), a non-ASCII unit outside a string
    /// (a Unicode identifier or whitespace the word matcher cannot delimit),
    /// or a bare argument key (a SHORTHAND property).
    private static func argsTransparent(_ s: Source, _ start: Int, _ end: Int) -> Bool {
        var i = start
        scan: while i < end {
            let c = s.u[i]
            if c == U.apos || c == U.quote {
                guard let close = skipString(s, i) else { return false }
                let after = skipWhitespaceAndComments(s, close)
                if s[after] == U.colon, s.slice(i + 1, close - 1).contains(U.backslash) { return false }
                i = close
            } else if c == U.backtick {
                guard let close = skipTemplate(s, i) else { return false }
                i = close
            } else if opensComment(s, i) {
                i = skipWhitespaceAndComments(s, i)
            } else if c == U.slash || c == U.lparen || c == U.rparen {
                return false
            } else if c == U.lbracket || c == U.question || c == U.backslash {
                return false
            } else if c >= 0x80 {
                return false
            } else if c == U.dot, s[i + 1] == U.dot, s[i + 2] == U.dot {
                return false
            } else {
                for key in argKeys where isWordAt(s, i, key) {
                    let after = skipWhitespaceAndComments(s, i + key.count)
                    if s[after] != U.colon { return false }
                    i += key.count
                    continue scan
                }
                i += 1
            }
        }
        return true
    }

    /// Unit offset of the VALUE of a top-level `key:` inside `[start, end)`.
    /// Bare `agent_type:` and quoted `"agent_type":` / `'agent_type':` both
    /// match, but only escape-free quoted keys and only at brace depth 1 —
    /// directly inside the call's argument object (the backend reads FLAT
    /// args). The scan STOPS when that object closes, so a second object never
    /// contributes keys. Duplicate keys take the LAST occurrence, the spelling
    /// the runtime uses.
    private static func findKey(_ s: Source, _ start: Int, _ end: Int, _ key: [UInt16]) -> Int? {
        var i = start
        var depth = 0
        var found: Int?
        scan: while i < end {
            let c = s.u[i]
            if c == U.apos || c == U.quote {
                guard let close = skipString(s, i) else { return nil }
                if depth == 1, close >= i + 2 {
                    let inner = s.slice(i + 1, close - 1)
                    let after = skipWhitespaceAndComments(s, close)
                    if s[after] == U.colon, !inner.contains(U.backslash), inner.elementsEqual(key) {
                        found = skipWhitespaceAndComments(s, after + 1)
                    }
                }
                i = close
            } else if c == U.backtick {
                guard let close = skipTemplate(s, i) else { return nil }
                i = close
            } else if opensComment(s, i) {
                i = skipWhitespaceAndComments(s, i)
            } else if c == U.lbrace {
                depth += 1
                i += 1
            } else if c == U.rbrace {
                // Closes the call's argument object (or a stray close):
                // everything after lies outside the flat args.
                if depth <= 1 { break scan }
                depth -= 1
                i += 1
            } else if depth == 1, isWordAt(s, i, key) {
                let after = skipWhitespaceAndComments(s, i + key.count)
                if s[after] == U.colon { found = skipWhitespaceAndComments(s, after + 1) }
                i += 1
            } else {
                i += 1
            }
        }
        return found
    }

    /// Whether the value ending at `end` is followed (past whitespace and
    /// comments) by `,` or `}` — the literal ends where its property ends. A
    /// literal followed by an operator (`"a" + b`) evaluates to something
    /// else at runtime.
    private static func valueEndsProperty(_ s: Source, _ end: Int) -> Bool {
        let after = skipWhitespaceAndComments(s, end)
        return s[after] == U.comma || s[after] == U.rbrace
    }

    /// The escape-free `'…'` / `"…"` string at `at` and the offset past its
    /// closing quote; nil when it holds a backslash (an escaped value could
    /// decode differently than it reads).
    private static func plainString(_ s: Source, _ at: Int) -> (value: String, end: Int)? {
        let quote = s[at]
        guard quote == U.apos || quote == U.quote, let end = skipString(s, at) else { return nil }
        let inner = s.slice(at + 1, end - 1)
        if inner.contains(U.backslash) { return nil }
        return (String(decoding: inner, as: UTF16.self), end)
    }

    /// The `agent_type` / `working_dir` value at `at`: an escape-free plain
    /// string ending where its property ends.
    private static func objectStringValue(_ s: Source, _ at: Int) -> String? {
        guard let r = plainString(s, at), valueEndsProperty(s, r.end) else { return nil }
        return r.value
    }

    /// The `task` value at `at`: a template literal through the minimal
    /// unescaper, or an escape-free plain string, ending where its property
    /// ends; anything else (numbers, shorthand) nil.
    private static func objectTaskValue(_ s: Source, _ at: Int) -> String? {
        guard let c = s[at] else { return nil }
        let r: (value: String, end: Int)?
        if c == U.backtick {
            r = templateText(s, at)
        } else if c == U.apos || c == U.quote {
            r = plainString(s, at)
        } else {
            return nil
        }
        guard let r, valueEndsProperty(s, r.end) else { return nil }
        return r.value
    }

    /// The `assistant_id` value at `at`, as text for the caller to narrow: an
    /// escape-free quoted value, or bare digits — `assistant_id: 3` is the
    /// common spelling.
    private static func assistantIdValue(_ s: Source, _ at: Int) -> String? {
        if let quoted = plainString(s, at) {
            return valueEndsProperty(s, quoted.end) ? quoted.value : nil
        }
        var i = at
        while i < s.count, s.u[i] >= U.zero, s.u[i] <= U.nine { i += 1 }
        if i == at || !valueEndsProperty(s, i) { return nil }
        return String(decoding: s.slice(at, i), as: UTF16.self)
    }

    private static func hexValue(_ c: UInt16) -> UInt32? {
        switch c {
        case 0x30...0x39: return UInt32(c - 0x30)
        case 0x61...0x66: return UInt32(c - 0x61 + 10)
        case 0x41...0x46: return UInt32(c - 0x41 + 10)
        default: return nil
        }
    }

    /// JS `\u` escapes denote scalar values: a lone surrogate or anything past
    /// U+10FFFF is invalid (Rust `char::from_u32` is `None` for both).
    private static func isScalarValue(_ v: UInt32) -> Bool {
        v <= 0x10FFFF && !(v >= 0xD800 && v <= 0xDFFF)
    }

    private static func readHex(_ s: Source, _ at: Int, _ count: Int) -> (value: UInt32, end: Int)? {
        if at + count > s.count { return nil }
        var v: UInt32 = 0
        for k in 0..<count {
            guard let d = hexValue(s.u[at + k]) else { return nil }
            v = v * 16 + d
        }
        return (v, at + count)
    }

    /// The cooked text of the template literal at `at` — the exact string the
    /// runtime hands the MCP listener — and the offset past its closing
    /// backtick. `\n \t \r \b \f \v \0 \\ \` \' \" \$ \u{…} \uXXXX \xXX`
    /// decode; a line continuation (`\` + CR / CRLF / LF) contributes nothing;
    /// a BARE CR or CRLF becomes one LF (ECMA-262's normalization rewrites
    /// only those, so U+2028 / U+2029 pass through). Nil for `${…}`, for any
    /// other escape, and for legacy octal.
    private static func templateText(_ s: Source, _ at: Int) -> (value: String, end: Int)? {
        var out: [UInt16] = []
        /// Append the scalar `v` as UTF-16 (JS `String.fromCodePoint`).
        func append(_ v: UInt32) {
            if v < 0x10000 {
                out.append(UInt16(v))
            } else {
                let w = v - 0x10000
                out.append(UInt16(0xD800 + (w >> 10)))
                out.append(UInt16(0xDC00 + (w & 0x3FF)))
            }
        }
        var i = at + 1
        while i < s.count {
            let c = s.u[i]
            if c == U.backtick { return (String(decoding: out, as: UTF16.self), i + 1) }
            if c == U.backslash {
                i += 1
                guard let e = s[i] else { return nil }
                i += 1
                switch e {
                case 0x6E: out.append(U.lf)        // \n
                case 0x74: out.append(U.tab)       // \t
                case 0x72: out.append(U.cr)        // \r
                case 0x62: out.append(0x08)        // \b
                case 0x66: out.append(U.ff)        // \f
                case 0x76: out.append(0x0B)        // \v
                case U.zero:
                    // Legacy octal (`\01` is not `\0` + `1`) is not supported.
                    if let next = s[i], next >= U.zero, next <= U.nine { return nil }
                    out.append(0)
                case U.backslash, U.backtick, U.dollar, U.apos, U.quote:
                    out.append(e)
                case 0x75:                          // \u
                    if s[i] == U.lbrace {
                        guard let close = s.indexOf(Word.rbrace, from: i) else { return nil }
                        let digits = s.slice(i + 1, close)
                        if digits.isEmpty || digits.count > 6 { return nil }
                        var v: UInt32 = 0
                        for d in digits {
                            guard let h = hexValue(d) else { return nil }
                            v = v * 16 + h
                        }
                        guard isScalarValue(v) else { return nil }
                        append(v)
                        i = close + 1
                    } else {
                        guard let r = readHex(s, i, 4), isScalarValue(r.value) else { return nil }
                        append(r.value)
                        i = r.end
                    }
                case 0x78:                          // \x
                    guard let r = readHex(s, i, 2), isScalarValue(r.value) else { return nil }
                    append(r.value)
                    i = r.end
                case U.cr:
                    // A line continuation: the newline is dropped.
                    if s[i] == U.lf { i += 1 }
                case U.lf:
                    break                           // a line continuation
                default:
                    return nil
                }
            } else if c == U.dollar, s[i + 1] == U.lbrace {
                return nil
            } else if c == U.cr {
                out.append(U.lf)
                i += 1
                if s[i] == U.lf { i += 1 }
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }
}
