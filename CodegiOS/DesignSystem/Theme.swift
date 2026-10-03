import SwiftUI
import UIKit

/// Design tokens for the codeg app — a Codex-like developer aesthetic with a
/// single refined accent and Liquid Glass surfaces floating above a subtle
/// gradient. Every color token is a *dynamic* color so the whole app themes at
/// runtime with zero call-site changes:
///
/// - **Light / Dark** is driven by the standard `userInterfaceStyle` trait, so
///   `Theme.bg`, the text colors, hairlines, etc. flip automatically when the
///   user picks a mode (or the system does). See `Color(light:dark:)`.
/// - **Accent** is driven by a *custom* `AccentPaletteTrait` bridged to the
///   SwiftUI environment (`\.codegAccent`). `Theme.accent` reads that trait, so
///   selecting a palette recolors every `Theme.accent` use live — again with no
///   call-site changes. The bridge is injected once in `RootView`.
enum Theme {
    // Backgrounds
    static let bg = Color(
        light: Color(red: 0.950, green: 0.955, blue: 0.965),   // ~#F2F4F6
        dark: Color(red: 0.039, green: 0.043, blue: 0.051)     // ~#0A0B0D
    )
    static let bgElevated = Color(
        light: Color(white: 1.0),
        dark: Color(red: 0.078, green: 0.085, blue: 0.098)
    )
    // White hairlines vanish on a light background, so the light variant is
    // black-based, not a lightened white.
    static let surfaceStroke = Color(light: .black.opacity(0.10), dark: .white.opacity(0.09))
    static let hairline = Color(light: .black.opacity(0.07), dark: .white.opacity(0.055))
    /// An inset "sunken" surface for code blocks and diffs — darker than the
    /// backdrop in dark mode, a faint gray in light mode.
    static let codeSurface = Color(light: .black.opacity(0.045), dark: .black.opacity(0.30))
    /// The transcript timeline's vertical spine. Deliberately a touch stronger
    /// than `hairline` so the continuous rail reads as a structural line rather
    /// than a separator that fades out.
    static let rail = Color(light: .black.opacity(0.20), dark: .white.opacity(0.16))

    /// Calm, shadowless container fills for message-body surfaces — tool cards,
    /// the plan, reasoning, the session header. `surface` is the top-level step;
    /// `surfaceNested` the fainter inset one level deep (group children, code/diff
    /// sub-panels). One two-step scale replaces the scattered
    /// `Color.primary.opacity(0.03…0.05)` literals so a reply reads as one material
    /// at two depths rather than five slightly-different greys. `surface` matches
    /// the prior top-level card fill exactly, so this unifies without a redesign.
    static let surface = Color.primary.opacity(0.05)
    static let surfaceNested = Color.primary.opacity(0.035)
    /// The highlight laid over a tappable row or card while it is pressed.
    static let pressed = Color.primary.opacity(0.09)

    // Text
    static let textPrimary = Color(light: Color(white: 0.11), dark: Color(white: 0.97))
    static let textSecondary = Color(light: Color(white: 0.38), dark: Color(white: 0.64))
    static let textTertiary = Color(light: Color(white: 0.55), dark: Color(white: 0.44))

    static let danger = Color(
        light: Color(red: 0.80, green: 0.18, blue: 0.18),
        dark: Color(red: 0.96, green: 0.46, blue: 0.46)
    )

    /// A semantic "caution / warning" amber — status dots (pending review,
    /// connecting), the context-gauge mid-zone, agent warn glyphs, and
    /// modified-file marks. Deliberately *not* accent-driven: a warning must read
    /// as amber even when the accent is Neutral or Blue. One dynamic, light/dark-
    /// aware token replaces the scattered `Color(red: 0.96, …)` literals so the
    /// hue stays consistent everywhere.
    static let warning = Color(
        light: Color(red: 0.80, green: 0.54, blue: 0.06),
        dark: Color(red: 0.96, green: 0.74, blue: 0.36)
    )

    // Accent — resolves the selected `AccentPalette` from the trait collection,
    // honoring light/dark per palette. A single dynamic color: no mutable global,
    // no per-call-site change, updates live when `\.codegAccent` is set.
    static let accent = Color(UIColor { tc in
        UIColor(tc.accentPalette.fill(dark: tc.userInterfaceStyle != .light))
    })
    /// The legible content color to place ON an accent fill (text/icons inside a
    /// filled chip or prominent button). Derived from the accent's luminance, so
    /// it stays readable across both palettes and both schemes.
    static let onAccent = Color(UIColor { tc in
        UIColor(tc.accentPalette.onColor(dark: tc.userInterfaceStyle != .light))
    })
    /// A faint accent wash (selection highlights, glass tints).
    static var accentDim: Color { accent.opacity(0.16) }

    enum Radius {
        static let xl: CGFloat = 26
        static let lg: CGFloat = 20
        static let md: CGFloat = 14
        static let sm: CGFloat = 10
    }

    /// Named motion curves so every animation shares one vocabulary and durations
    /// don't drift. `chrome` is the house spring for bars/chips/toggles/inserts;
    /// `content` is a gentle no-overshoot fade for loading↔loaded swaps; `expand`
    /// for card disclosure; `press` for tactile button scale; `scroll` for
    /// user-initiated jumps. The streaming auto-follow scroll is deliberately NOT
    /// animated (animating per 50ms chunk stutters) — it stays a plain `scrollTo`.
    enum Motion {
        static let chrome = Animation.snappy(duration: 0.24)
        static let content = Animation.smooth(duration: 0.26)
        static let expand = Animation.snappy(duration: 0.22)
        static let press = Animation.snappy(duration: 0.12)
        static let scroll = Animation.snappy(duration: 0.30)
    }

    /// Reading-text tokens for assistant/user message bodies. Semantic fonts so
    /// Dynamic Type still scales; explicit line spacing for a comfortable
    /// ~1.45× line height (the SwiftUI `Text` default is a cramped ~1.16×, which
    /// is what made dense replies feel uncomfortable to read). Centralized here
    /// so the whole transcript shares one rhythm — `MarkdownContent`,
    /// `MarkdownText`, and `CodeBlockView` all read these instead of scattering
    /// `.callout` / magic spacings at each call site.
    enum Typography {
        /// Primary reading prose (paragraphs, list items, quotes).
        static let messageBody: Font = .body                 // 17pt @ default Dynamic Type
        static let messageLineSpacing: CGFloat = 5           // ≈1.45× effective line box
        /// Vertical rhythm between blocks within a single message.
        static let blockSpacing: CGFloat = 12
        static let listItemSpacing: CGFloat = 5
        /// Blockquote — same size as body, a touch tighter; color applied at site.
        static let quote: Font = .body
        static let quoteLineSpacing: CGFloat = 4
        /// Fenced/console code in a reading context.
        static let code: Font = .mono(13)
        static let codeLineSpacing: CGFloat = 2
        /// Heading scale — kept at the existing sizes (do not shrink); the fix is
        /// the added line spacing + consistent rhythm, not smaller headings.
        static func heading(_ level: Int) -> Font {
            switch level {
            case 1: return .title2
            case 2: return .title3
            case 3: return .headline
            default: return .subheadline
            }
        }
        static let headingLineSpacing: CGFloat = 3
        /// Per-level heading weight. Major headings (h1/h2) are bold; minor ones
        /// (h3/h4) semibold, so the levels differ by *weight* as well as size.
        /// Previously every level was force-set to `.bold`, which collapsed h3/h4
        /// into a ~2pt size step at one weight — erasing the hierarchy. Sizes are
        /// unchanged (the intentional decision); only the weight ladder is restored.
        static func headingWeight(_ level: Int) -> Font.Weight {
            switch level {
            case 1, 2: return .bold
            default:   return .semibold
            }
        }

        // MARK: Metadata / chrome tier
        // Semantic fonts (so they scale with Dynamic Type) replacing the ~8 ad-hoc
        // `.system(size: 8.5…12)` literals scattered through the transcript chrome,
        // which froze at one size and bypassed the token system. Numeric chrome
        // adds `.monospacedDigit()` at the call site so live counters don't jitter.
        /// Tool-card / group titles.
        static let cardTitle: Font = .subheadline.weight(.semibold)
        /// The dominant chrome label — footer meta, header chips, relative time.
        static let metaLabel: Font = .caption2.weight(.medium)
        /// Tiny emphatic labels — mode badges, "N failed", language tags.
        static let microLabel: Font = .caption2.weight(.bold)
        /// Code chrome (copy button, language header, expand toggles) — mono, small.
        static let codeMeta: Font = .mono(10)
        /// Dense diff/code rows — a touch smaller than reading `code`, own rhythm.
        static let diffCode: Font = .mono(11.5)
        static let diffLineSpacing: CGFloat = 2
        /// Diff line-number gutter (mono is already tabular-by-face).
        static let diffGutter: Font = .mono(10)
    }

    enum Layout {
        /// Horizontal margin for a screen's top-level content (the outer scroll
        /// container), matched to the iOS standard navigation-bar layout margin
        /// so cards/rows line up with the large title and the toolbar buttons
        /// above them on both edges. Pixel-measured on iPhone 17: the native nav
        /// bar pins its large title and bar-button items at 16pt from the screen
        /// edge, and that inset can't be moved cleanly (the appearance API
        /// crashes; per-instance margin overrides are no-ops). The floating tab
        /// bar capsule sits at a wider ~21pt inset by system design — Apple's own
        /// apps keep content at the standard margin and let the glass tab bar
        /// float narrower, so we deliberately do NOT widen content to meet it.
        /// Card/row/sheet *internal* padding is unrelated and stays as-is.
        static let screenHMargin: CGFloat = 16

        /// Shared vertical rhythm for top-level scroll screens so the tabs feel
        /// built by one hand. Settings already breathed at ~22/8; the lists were
        /// tighter (12/2) and started higher under the nav bar. These tokens give
        /// every screen the same section gap and top/bottom insets.
        static let sectionSpacing: CGFloat = 20
        static let screenTopInset: CGFloat = 8
        static let screenBottomInset: CGFloat = 28
    }
}

// MARK: - Diff palette

/// Green/red palette shared across the diff views and the plan/tool "done" marks.
/// Dynamic per scheme like every other token: the light variants are deepened so
/// `+`/`−` lines stay legible on the near-white light background (the old fixed
/// pastels washed out there). Deliberately NOT accent-driven — a diff must read
/// green/red whatever the chosen accent is (same rationale as `Theme.warning`).
enum DiffPalette {
    static let addText = Color(
        light: Color(red: 0.13, green: 0.52, blue: 0.31),
        dark:  Color(red: 0.55, green: 0.90, blue: 0.62)
    )
    static let delText = Color(
        light: Color(red: 0.78, green: 0.20, blue: 0.20),
        dark:  Color(red: 0.96, green: 0.52, blue: 0.52)
    )
    static let addBg = Color(
        light: Color(red: 0.30, green: 0.70, blue: 0.42).opacity(0.16),
        dark:  Color(red: 0.30, green: 0.80, blue: 0.45).opacity(0.15)
    )
    static let delBg = Color(
        light: Color(red: 0.90, green: 0.30, blue: 0.30).opacity(0.12),
        dark:  Color(red: 0.95, green: 0.40, blue: 0.40).opacity(0.13)
    )
}

// MARK: - Accent palettes

/// The selectable accent color schemes. `neutral` — a refined monochrome gray —
/// is the default selection and is listed first; the colorful schemes follow.
/// The raw value is the key stored in `AccentPaletteTrait` and persisted by index
/// in `AppearanceStore`, so the raw values are pinned explicitly: `neutral` takes
/// a fresh index (8) while the existing schemes keep 0–7, so upgrading an install
/// never reinterprets a previously saved choice.
enum AccentPalette: Int, CaseIterable, Identifiable {
    case neutral = 8
    case mint = 0, blue = 1, indigo = 2, purple = 3, pink = 4, orange = 5, teal = 6, red = 7
    // 2026 trend hues, appended last so the picker order is unchanged above them.
    // Fresh raw indices (9–11) keep every previously saved selection mapping to
    // the same palette — see the type doc. Mocha = "Mocha Mousse" (a warm brown),
    // Butter = soft "butter yellow", Dusk = the muted twilight violet "Future
    // Dusk" — each fills a hue the original nine didn't cover.
    case mocha = 9, butter = 10, dusk = 11

    var id: Int { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .neutral: "Neutral"
        case .mint: "Mint"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .orange: "Orange"
        case .teal: "Teal"
        case .red: "Red"
        case .mocha: "Mocha"
        case .butter: "Butter"
        case .dusk: "Dusk"
        }
    }

    /// Per-mode fill RGB. The dark variant is the brighter/airier tone that reads
    /// on the near-black backdrop; the light variant is deeper/more saturated so
    /// it stays legible on a near-white backdrop.
    private var rgb: (dark: (Double, Double, Double), light: (Double, Double, Double)) {
        switch self {
        case .neutral: return ((0.90, 0.91, 0.93), (0.16, 0.17, 0.20))
        case .mint:   return ((0.40, 0.88, 0.70), (0.06, 0.58, 0.42))
        case .blue:   return ((0.39, 0.66, 1.00), (0.00, 0.45, 0.92))
        case .indigo: return ((0.56, 0.60, 0.99), (0.29, 0.31, 0.86))
        case .purple: return ((0.76, 0.55, 1.00), (0.52, 0.26, 0.83))
        case .pink:   return ((1.00, 0.45, 0.71), (0.86, 0.16, 0.49))
        case .orange: return ((1.00, 0.62, 0.30), (0.85, 0.42, 0.05))
        case .teal:   return ((0.30, 0.82, 0.86), (0.00, 0.52, 0.58))
        case .red:    return ((1.00, 0.45, 0.45), (0.82, 0.19, 0.20))
        case .mocha:  return ((0.82, 0.64, 0.54), (0.51, 0.36, 0.29))
        case .butter: return ((0.98, 0.84, 0.42), (0.70, 0.53, 0.05))
        case .dusk:   return ((0.60, 0.55, 0.80), (0.35, 0.31, 0.54))
        }
    }

    /// The accent fill for the given scheme.
    func fill(dark: Bool) -> Color {
        let c = dark ? rgb.dark : rgb.light
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    /// Black-or-white content color for legibility on `fill(dark:)`, chosen by
    /// relative luminance.
    func onColor(dark: Bool) -> Color {
        let c = dark ? rgb.dark : rgb.light
        let luminance = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        return luminance > 0.6 ? Color(white: 0.06) : .white
    }

    /// A self-contained dynamic swatch (this palette's own color, resolved for
    /// the current scheme) for the picker — independent of which accent is
    /// currently selected.
    var swatch: Color {
        Color(UIColor { UIColor(self.fill(dark: $0.userInterfaceStyle != .light)) })
    }
}

// MARK: - Accent trait ↔ environment bridge

/// A custom UIKit trait carrying the selected accent palette by raw index, so
/// dynamic `UIColor`s can resolve the accent the same way they resolve light/dark.
struct AccentPaletteTrait: UITraitDefinition {
    static let defaultValue = AccentPalette.neutral.rawValue
}

extension UITraitCollection {
    var accentPalette: AccentPalette {
        AccentPalette(rawValue: self[AccentPaletteTrait.self]) ?? .neutral
    }
}

/// Bridges the SwiftUI `\.codegAccent` environment value to `AccentPaletteTrait`.
/// Setting the environment value writes through to the trait collection, which
/// propagates to all descendants (and presented sheets) and re-resolves every
/// accent-backed dynamic color in place — no view rebuild.
struct CodegAccentKey: EnvironmentKey, UITraitBridgedEnvironmentKey {
    static let defaultValue: AccentPalette = .neutral

    static func read(from traitCollection: UITraitCollection) -> AccentPalette {
        traitCollection.accentPalette
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: AccentPalette) {
        mutableTraits[AccentPaletteTrait.self] = value.rawValue
    }
}

extension EnvironmentValues {
    var codegAccent: AccentPalette {
        get { self[CodegAccentKey.self] }
        set { self[CodegAccentKey.self] = newValue }
    }
}

extension Font {
    /// Monospaced face for code, file paths, IDs, and token counts.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// A faint hairline stroke that gives glass surfaces definition.
    func hairlineBorder(_ cornerRadius: CGFloat, color: Color = Theme.surfaceStroke) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: 0.75)
        )
    }
}

extension Color {
    /// A dynamic color that resolves to `light` or `dark` per the active
    /// `userInterfaceStyle`. Re-resolves automatically when the color scheme
    /// flips at runtime — the stored value is the dynamic provider, not a baked
    /// RGBA, so there's no stale-trait trap.
    init(light: Color, dark: Color) {
        self = Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(light) : UIColor(dark) })
    }

    /// Parse a `#RRGGBB` / `RRGGBB` (optionally `#RRGGBBAA`) hex string — the
    /// format the server uses for folder colors. Returns nil on anything else.
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        if hex.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self = Color(red: r, green: g, blue: b, opacity: a)
    }
}
