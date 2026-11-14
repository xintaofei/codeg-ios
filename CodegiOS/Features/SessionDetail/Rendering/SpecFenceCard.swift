import SwiftUI

/// json-render specs in assistant replies (codeg 0.44). An agent with the
/// `ui-render` skill answers with a ```` ```spec ```` fence of JSON Patch lines
/// (RFC 6902) that build a `{root, elements, state}` UI tree, which the desktop
/// and web clients draw as an interactive card. This client does not render
/// that UI yet (phase 0): it recognises the fence the way the web does and
/// shows a folded card in place of the raw JSONL.
enum MarkdownSpec {
    /// The fence is a json-render spec: labelled `spec` (the info string's
    /// first word, exactly — `language-spec` on the web) and its first
    /// non-empty line is a complete patch. A fence labelled `spec` is also how
    /// RPM spec files are shown, and those stay code; so does a first line
    /// still being written.
    static func isSpecFence(language: String?, code: String) -> Bool {
        guard let language, firstWord(language) == "spec" else { return false }
        return isSpecStream(code)
    }

    /// `isSpecStream` (`src/lib/json-render/spec.ts`): the first non-empty line
    /// parses as a patch.
    static func isSpecStream(_ source: String) -> Bool {
        var first: Substring?
        // `isNewline`, not `"\n"`: a CRLF is one `Character`.
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            first = line
            break
        }
        guard let first else { return false }
        return isPatchLine(first)
    }

    /// json-render's `parseSpecStreamLine` returning non-null: a JSON object
    /// line whose `op` is truthy and that has a `path`.
    static func isPatchLine<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"], isTruthy(op),
              object.keys.contains("path") else { return false }
        return true
    }

    /// JavaScript truthiness for a decoded JSON value.
    private static func isTruthy(_ value: Any) -> Bool {
        switch value {
        case is NSNull: return false
        case let s as String: return !s.isEmpty
        case let n as NSNumber:
            // JSONSerialization hands booleans and numbers back as NSNumber.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            let d = n.doubleValue
            return d != 0 && !d.isNaN
        default: return true
        }
    }

    private static func firstWord(_ info: String) -> Substring {
        let trimmed = info.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.prefix(while: { $0 != " " && $0 != "\t" })
    }
}

/// The folded stand-in for a json-render card: what it is, where it renders,
/// and the spec's source behind a disclosure (the same code block the fence
/// would otherwise be).
struct SpecFenceCard: View {
    let source: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.expand) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interactive card")
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Rendered on desktop and web")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))

            if expanded {
                CodeBlockView(code: source, language: "spec")
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
    }
}
