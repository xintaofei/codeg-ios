import SwiftUI

/// How big a tag chip is drawn: `.row` inline after a list row's title,
/// `.regular` everywhere else.
enum TagChipSize {
    case row
    case regular

    var font: Font {
        switch self {
        case .row: return .system(size: 10, weight: .medium)
        case .regular: return .caption.weight(.medium)
        }
    }

    /// The widest a chip gets — padding included — before its name truncates.
    var maxWidth: CGFloat {
        switch self {
        case .row: return 76
        case .regular: return 180
        }
    }

    var hPad: CGFloat { self == .row ? 5 : 8 }
    var vPad: CGFloat { self == .row ? 1.5 : 3 }
}

extension Color {
    /// A packed `0xAARRGGBB` value (what ``TagSwatch`` computes).
    init(argb: UInt32) {
        self = Color(
            .sRGB,
            red: Double((argb >> 16) & 0xff) / 255,
            green: Double((argb >> 8) & 0xff) / 255,
            blue: Double(argb & 0xff) / 255,
            opacity: Double((argb >> 24) & 0xff) / 255
        )
    }
}

/// A tag colour as the three dynamic colours its chip is drawn with: the
/// light and dark ``TagSwatch``es behind one `Color(light:dark:)` each, so a
/// chip follows a theme flip without being rebuilt. A colour that isn't
/// `#rrggbb` gets the neutral chip.
struct TagChipColors {
    let background: Color
    let foreground: Color
    let border: Color

    init(_ hex: String) {
        if let light = TagSwatch.make(hex, dark: false), let dark = TagSwatch.make(hex, dark: true) {
            background = Color(light: Color(argb: light.background), dark: Color(argb: dark.background))
            foreground = Color(light: Color(argb: light.foreground), dark: Color(argb: dark.foreground))
            border = Color(light: Color(argb: light.border), dark: Color(argb: dark.border))
        } else {
            background = Color.primary.opacity(0.08)
            foreground = Theme.textSecondary
            border = .clear
        }
    }
}

/// One tag as a chip, in its colour, readable in either theme (web
/// `.forge-label`). The name is user data and drawn verbatim.
struct TagChip: View {
    let name: String
    let color: String
    var size: TagChipSize = .regular
    /// The branch chip: a branch glyph ahead of the name.
    var isBranch = false

    var body: some View {
        let colors = TagChipColors(color)
        let capped = CappedWidth(max: size.maxWidth)
        capped {
            HStack(spacing: 2) {
                if isBranch {
                    Image(systemName: "arrow.triangle.branch")
                        .font(size.font)
                        .imageScale(.small)
                }
                Text(verbatim: name)
                    .font(size.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(colors.background, in: Capsule())
            .overlay(Capsule().strokeBorder(colors.border, lineWidth: 0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBranch ? Text("Branch: \(name)") : Text(verbatim: name))
    }
}

/// A neutral "+N" chip for the tags a row has no room for.
struct MoreTagsChip: View {
    let count: Int
    var size: TagChipSize = .row

    var body: some View {
        Text(verbatim: "+\(count)")
            .font(size.font)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .fixedSize()
            .accessibilityLabel(Text("More tags: \(count)"))
    }
}

/// What a list row draws after its title: its tags this client knows, in
/// display order, and its branch when the branch tag is on.
struct RowTags: Equatable {
    var tags: [ConversationTag] = []
    var branch: String?
    var branchColor: String = BranchTagSetting.defaultColor

    static let none = RowTags()

    var isEmpty: Bool { tags.isEmpty && branch == nil }

    /// What `conversation` draws: its tags this client knows, in display order,
    /// and its branch when the branch tag is on — nothing on a sub-session (its
    /// parent row carries them). Every surface that shows a conversation's
    /// chips resolves them here, so a row and the session header agree. Pure.
    static func resolve(_ conversation: ConversationSummary, tagsByID: [Int: ConversationTag],
                        branchTag: BranchTagSetting) -> RowTags {
        guard conversation.canCarryTags else { return .none }
        let branch = ConversationTags.branchChip(for: conversation, enabled: branchTag.enabled)
        let resolved = ConversationTags.resolve(conversation.tagIds, in: tagsByID)
        guard branch != nil || !resolved.isEmpty else { return .none }
        return RowTags(tags: resolved, branch: branch, branchColor: branchTag.color)
    }
}

/// A row's chips (web `ConversationTagChips`, `CARD_TAG_LIMIT`): the branch
/// first — it counts toward `limit` and never folds into "+N" — then the tags,
/// the rest as "+N".
struct RowTagChips: View {
    let decoration: RowTags
    var limit = 2

    var body: some View {
        let room = max(0, limit - (decoration.branch == nil ? 0 : 1))
        let shown = Array(decoration.tags.prefix(room))
        let hidden = decoration.tags.count - shown.count
        HStack(spacing: 3) {
            if let branch = decoration.branch {
                TagChip(name: branch, color: decoration.branchColor, size: .row, isBranch: true)
            }
            ForEach(shown) { tag in
                TagChip(name: tag.name, color: tag.color, size: .row)
            }
            if hidden > 0 {
                MoreTagsChip(count: hidden)
            }
        }
    }
}

/// A row title with its chips after it. The chips take what they need and the
/// title the rest — but the title always keeps `titleFloor` (web: the chips'
/// `max-w-[calc(100%-3.875rem)]`), so on a narrow row the chips give way. A
/// floor on the title instead would hold a short title's box open and push the
/// chips off it.
struct TitleWithChips: Layout {
    var spacing: CGFloat = 6
    var titleFloor: CGFloat = 56

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (title, chips) = widths(for: proposal.width, subviews: subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: title + (chips > 0 ? spacing + chips : 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (title, chips) = widths(for: bounds.width, subviews: subviews)
        guard let first = subviews.first else { return }
        first.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: title, height: bounds.height))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX + title + spacing, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: chips, height: bounds.height))
        }
    }

    /// The title's and the chips' widths for `available` (nil = ideal).
    private func widths(for available: CGFloat?, subviews: Subviews) -> (title: CGFloat, chips: CGFloat) {
        guard let first = subviews.first else { return (0, 0) }
        let titleIdeal = first.sizeThatFits(.unspecified).width
        guard subviews.count > 1 else { return (min(titleIdeal, available ?? titleIdeal), 0) }
        let chipsIdeal = subviews[1].sizeThatFits(.unspecified).width
        guard let available else { return (titleIdeal, chipsIdeal) }
        let chips = min(chipsIdeal, max(0, available - spacing - min(titleFloor, titleIdeal)))
        let title = min(titleIdeal, max(0, available - spacing - chips))
        return (title, chips)
    }
}

/// Caps its content's width WITHOUT claiming the cap when the content is
/// narrower — `.frame(maxWidth:)` would stretch a short chip to the cap.
struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = Swift.min(proposal.width ?? max, max)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The preset swatches (strong row, then soft row) for picking a tag colour.
struct TagColorPresetGrid: View {
    let selected: String
    var isEnabled = true
    let onPick: (String) -> Void

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 9) }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ConversationTags.colorPresets, id: \.self) { hex in
                swatch(hex)
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let isSelected = hex.caseInsensitiveCompare(selected) == .orderedSame
        let check = TagSwatch.make(hex, dark: false).map { Color(argb: $0.foreground) } ?? .white
        return Button { onPick(hex) } label: {
            Circle()
                .fill(Color(hexString: hex) ?? .gray)
                .frame(width: 28, height: 28)
                .overlay {
                    Circle().strokeBorder(isSelected ? Theme.textPrimary : Theme.surfaceStroke,
                                          lineWidth: isSelected ? 2 : 0.75)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(check)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: hex))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
