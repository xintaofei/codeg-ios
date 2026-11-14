import Foundation

/// How one fenced code block is drawn. Most fences are code; a few labels
/// claim the fence for a renderer of its own (codeg 0.44 web parity):
///
/// - ```` ```mermaid ```` — a diagram, in any Markdown (the web installs its
///   `pre` override on every Streamdown). Drawn only once its source is final:
///   the web re-renders a diagram on every streamed delta, this client renders
///   it once, when the fence has closed or the text stopped streaming.
/// - ```` ```spec ```` — a json-render card, in an assistant reply only.
///
/// PlantUML (```` ```plantuml ```` / ```` ```puml ````) is not drawn: it stays
/// code.
enum MarkdownFenceKind: Equatable {
    /// `ready` once the source can no longer change.
    case mermaid(ready: Bool)
    case spec
    case code
}

enum MarkdownFence {
    /// The fence's language: the first word of its info string (mdast `lang`).
    static func language(_ info: String?) -> Substring? {
        guard let info else { return nil }
        let trimmed = info.drop(while: { $0 == " " || $0 == "\t" })
        let word = trimmed.prefix(while: { $0 != " " && $0 != "\t" })
        return word.isEmpty ? nil : word
    }

    /// `language-mermaid` and nothing else — case-sensitive, as the web's
    /// `MERMAID_LANGUAGE` class match is; `mermaidx` and `mermaid-lite` are code.
    static func isMermaid(language info: String?) -> Bool {
        language(info) == "mermaid"
    }

    /// Whether a fence's source is final. Once the text has stopped streaming
    /// it is, closed or not. While it streams, the fence has to be closed and
    /// its closing line finished: a closing fence that is still the last thing
    /// received may yet turn out to be a longer run of backticks or a line of
    /// code (the web waits for the line ending the same way, `lineDone`).
    static func isSettled(closed: Bool, streaming: Bool, isLastBlock: Bool,
                          sourceEndsWithNewline: Bool) -> Bool {
        if !streaming { return true }
        guard closed else { return false }
        return !isLastBlock || sourceEndsWithNewline
    }

    /// The renderer for a fence. `settled` is `isSettled(...)`.
    static func kind(language info: String?, code: String, closed: Bool, settled: Bool,
                     assistantReply: Bool) -> MarkdownFenceKind {
        if isMermaid(language: info) { return .mermaid(ready: settled) }
        guard assistantReply else { return .code }
        if MarkdownSpec.isSpecFence(language: info, code: code) { return .spec }
        return .code
    }
}
