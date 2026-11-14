import CoreGraphics
import SwiftUI

// MARK: - Setting

/// "Render HTML in chat" — the web's `workspace:chat-html-rendering`, a
/// per-device switch (here UserDefaults, there localStorage), off by default.
enum ChatHtmlPreference {
    static let key = "codeg.chat.htmlRendering"
}

private struct ChatHtmlRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether ```` ```html ```` fences in replies render as previews. Set once
    /// at the root from the stored setting; false wherever it is not set.
    var chatHtmlRendering: Bool {
        get { self[ChatHtmlRenderingKey.self] }
        set { self[ChatHtmlRenderingKey.self] = newValue }
    }
}

// MARK: - Theme

/// The theme a preview is drawn in: the color scheme and the accent. Part of
/// every cache key.
struct ChatHtmlTheme: Hashable, Sendable {
    let dark: Bool
    let accent: AccentPalette

    var key: String { "\(dark ? "dark" : "light")-\(accent.rawValue)" }

    /// The surface the document is drawn on — the inline card's color.
    var surfaceCSS: String { RichBlockPalette(dark: dark).css }

    /// The theme tokens codeg shares with the Codex visualize skill's contract
    /// (`readHtmlPreviewTheme`): the web's default (neutral) preset, with the
    /// surface as `--background` and the app's accent as `--primary`/`--ring`.
    var variablesCSS: String {
        let accentComponents = accent.components(dark: dark)
        let primary = Self.css(accentComponents.fill)
        let onPrimary = Self.css(accentComponents.on)
        var tokens: [(String, String)] = [("background", surfaceCSS)]
        if dark {
            tokens += [
                ("foreground", "oklch(0.985 0 0)"),
                ("card", "oklch(0.205 0 0)"),
                ("card-foreground", "oklch(0.985 0 0)"),
                ("popover", "oklch(0.205 0 0)"),
                ("popover-foreground", "oklch(0.985 0 0)"),
                ("primary", primary),
                ("primary-foreground", onPrimary),
                ("secondary", "oklch(0.269 0 0)"),
                ("secondary-foreground", "oklch(0.985 0 0)"),
                ("muted", "oklch(0.269 0 0)"),
                ("muted-foreground", "oklch(0.708 0 0)"),
                ("accent", "oklch(0.371 0 0)"),
                ("accent-foreground", "oklch(0.985 0 0)"),
                ("destructive", "oklch(0.704 0.191 22.216)"),
                ("border", "oklch(1 0 0 / 10%)"),
                ("input", "oklch(1 0 0 / 15%)"),
                ("ring", primary),
            ]
        } else {
            tokens += [
                ("foreground", "oklch(0.145 0 0)"),
                ("card", "oklch(1 0 0)"),
                ("card-foreground", "oklch(0.145 0 0)"),
                ("popover", "oklch(1 0 0)"),
                ("popover-foreground", "oklch(0.145 0 0)"),
                ("primary", primary),
                ("primary-foreground", onPrimary),
                ("secondary", "oklch(0.97 0 0)"),
                ("secondary-foreground", "oklch(0.205 0 0)"),
                ("muted", "oklch(0.97 0 0)"),
                ("muted-foreground", "oklch(0.556 0 0)"),
                ("accent", "oklch(0.97 0 0)"),
                ("accent-foreground", "oklch(0.205 0 0)"),
                ("destructive", "oklch(0.58 0.22 27)"),
                ("border", "oklch(0.922 0 0)"),
                ("input", "oklch(0.922 0 0)"),
                ("ring", primary),
            ]
        }
        var declarations = tokens.map { "--\($0.0):\($0.1)" }
        // The skill aliases its first chart series to `--primary`; keep its
        // own blue for charts, as the web does.
        declarations.append("--viz-series-1:var(--blue)")
        return ":root{\(declarations.joined(separator: ";"))}"
    }

    private static func css(_ c: (red: Double, green: Double, blue: Double)) -> String {
        func channel(_ v: Double) -> String { String(format: "%.0f", (v * 255).rounded()) }
        return "rgb(\(channel(c.red)),\(channel(c.green)),\(channel(c.blue)))"
    }
}

// MARK: - Sizes

/// The preview's heights (`html-code-preview.tsx`): the document's measured
/// height clamped to 96–12,000 points, 160 before it is known, and at most
/// 640 shown until "Show all".
enum HtmlPreviewMetrics {
    static let minHeight: CGFloat = 96
    static let maxHeight: CGFloat = 12_000
    static let placeholderHeight: CGFloat = 160
    static let collapsedHeight: CGFloat = 640

    /// A measured height as the preview uses it. Nothing to measure (0, or
    /// not a number) leaves the default height, as on the web, where the
    /// frame keeps it until a height is reported.
    static func clamp(_ measured: Double) -> CGFloat {
        guard measured.isFinite, measured > 0 else { return placeholderHeight }
        return min(maxHeight, max(minHeight, CGFloat(measured.rounded(.up))))
    }

    /// Taller than the collapsed view: offers "Show all".
    static func overflows(_ height: CGFloat) -> Bool {
        height > collapsedHeight
    }

    /// How much of a document `height` tall is shown.
    static func visibleHeight(_ height: CGFloat, expanded: Bool) -> CGFloat {
        expanded || !overflows(height) ? height : collapsedHeight
    }

    /// How much of the document the picture covers from the top: the
    /// collapsed view needs only its first 640 points.
    static func pictureClip(expanded: Bool) -> CGFloat {
        expanded ? maxHeight : collapsedHeight
    }
}

// MARK: - View memory

/// The view the reader picked per source — Code or Preview, collapsed or all
/// — so a preview drawn again as a new row (as a reply settles, or a row is
/// recycled) comes back as it was (the web's `views` map: 32 entries / 1 MB
/// of keys).
@MainActor
final class HtmlPreviewViewMemory {
    static let shared = HtmlPreviewViewMemory()

    struct Choice: Equatable {
        var preview = true
        var expanded = false
    }

    static let limit = 32
    static let maxBytes = 1024 * 1024

    private var entries: [String: Choice] = [:]
    /// Oldest first.
    private var order: [String] = []
    private(set) var bytes = 0

    func choice(for source: String) -> Choice {
        entries[source] ?? Choice()
    }

    func remember(_ choice: Choice, for source: String) {
        let cost = Self.cost(source)
        if entries.removeValue(forKey: source) != nil {
            order.removeAll { $0 == source }
            bytes -= cost
        }
        // A view preference alone should never pin a multi-megabyte source.
        guard cost <= Self.maxBytes else { return }
        entries[source] = choice
        order.append(source)
        bytes += cost
        while entries.count > Self.limit || bytes > Self.maxBytes, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
            bytes -= Self.cost(oldest)
        }
    }

    var count: Int { entries.count }

    private static func cost(_ source: String) -> Int {
        64 + source.utf16.count * 2
    }
}
