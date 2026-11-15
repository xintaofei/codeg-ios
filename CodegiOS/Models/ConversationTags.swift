import Foundation

/// A conversation tag (Rust `ConversationTagDetail`). `folderId` is its scope:
/// nil for a GLOBAL tag, otherwise the ROOT folder whose conversations — its
/// worktrees' included — it is offered on. A tag's scope never changes, and
/// `color` is always a normalized lowercase `#rrggbb` (the server's rule).
struct ConversationTag: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let folderId: Int?
    var name: String
    var color: String
    /// Position within its scope.
    var sortOrder: Int

    init(id: Int, folderId: Int? = nil, name: String, color: String, sortOrder: Int = 0) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, folderId, name, color, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        folderId = try c.decodeIfPresent(Int.self, forKey: .folderId)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(String.self, forKey: .color)
        // Always sent today; tolerated absent so a lean row can't fail the list.
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

/// The app-wide "branch tag" setting (Rust `ConversationBranchTag`): whether
/// each conversation's `git_branch` — the one it started on — is drawn as a
/// chip ahead of its tags, and in which colour. One setting for the whole
/// server, not stored per conversation.
struct BranchTagSetting: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var color: String = BranchTagSetting.defaultColor

    /// The server's default (`DEFAULT_BRANCH_TAG_COLOR`): the gray preset.
    static let defaultColor = "#6e7781"
}

/// What ``Notification.Name.conversationTagsDidChange`` carries: the tags the
/// server now holds for one conversation, and the server it holds them on (a
/// screen bound to another server must ignore it — ids are a server's own).
struct ConversationTagsChange: Sendable {
    /// ``CodegClient/tagEndpoint`` of the server that answered.
    let endpoint: String
    let conversationID: Int
    let tagIDs: [Int]
}

/// The rules every tag surface shares (codeg web `lib/conversation-tags.ts`):
/// which tags a conversation may carry, the order they are drawn in, the
/// colours offered for new ones, and what a filter matches. Pure, for tests.
///
/// A tag with no folder is GLOBAL and fits every conversation, chat ones
/// included; any other belongs to one ROOT folder and fits only that folder's
/// conversations and its worktrees'. Chat folders never own tags.
enum ConversationTags {
    /// Longest name the server keeps — it trims, then caps at this many
    /// characters (Rust `chars()`, so Unicode scalars).
    static let maxNameLength = 64

    /// The colours offered when creating or recolouring a tag: a strong row and
    /// a soft row in the same hue order. The web measured every one against the
    /// chip treatment (``TagSwatch``) in both themes; re-measure there before
    /// changing a value.
    static let colorPresets: [String] = [
        "#cf222e", "#bc4c00", "#9a6700", "#1a7f37", "#0f766e", "#0969da", "#8250df", "#bf3989", "#6e7781",
        "#fecaca", "#fed7aa", "#fde68a", "#bbf7d0", "#99f6e4", "#bfdbfe", "#ddd6fe", "#fbcfe8", "#e2e8f0",
    ]
    /// How many presets make up the strong row (the rest are the soft row).
    static let strongColorCount = 9

    /// The colour a NEW tag starts with: the first strong preset none of
    /// `neighbours` — the tags it will be seen beside — uses yet, so tags made
    /// back to back come out distinguishable; once all are taken, by count.
    static func nextColor(neighbours: [ConversationTag]) -> String {
        let used = Set(neighbours.map { $0.color.lowercased() })
        let strong = Array(colorPresets.prefix(strongColorCount))
        return strong.first { !used.contains($0) } ?? strong[neighbours.count % strong.count]
    }

    /// `#rgb` / `#rrggbb` (any case, surrounding space allowed) → lowercase
    /// `#rrggbb`, or nil: the server's own rule, so the form can validate first.
    static func normalizeColor(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let hex = trimmed.dropFirst()
        guard hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        switch hex.count {
        case 3: return "#" + hex.map { "\($0)\($0)" }.joined().lowercased()
        case 6: return "#" + hex.lowercased()
        default: return nil
        }
    }

    /// A name as the server will keep it: trimmed, capped at
    /// ``maxNameLength`` Unicode scalars.
    static func cappedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > maxNameLength else { return trimmed }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(maxNameLength))
        return String(scalars)
    }

    /// The folder whose own tags a conversation in `folder` is offered: its
    /// root for a regular folder (worktrees follow their repo), none for a chat
    /// folder or one this client doesn't know.
    static func scopeFolderID(_ folder: FolderDetail?) -> Int? {
        guard let folder, folder.kind == .regular else { return nil }
        return folder.parentId ?? folder.id
    }

    /// Whether `tag` may go on a conversation whose folder scope is `scope`.
    static func fits(_ tag: ConversationTag, scope: Int?) -> Bool {
        tag.folderId == nil || tag.folderId == scope
    }

    /// Display order: global tags first, then by folder, each scope in its
    /// `sortOrder` (ties on id) — the order the server lists them in,
    /// re-established so a set assembled from any source reads the same.
    static func precedes(_ a: ConversationTag, _ b: ConversationTag) -> Bool {
        if a.folderId != b.folderId {
            guard let left = a.folderId else { return true }
            guard let right = b.folderId else { return false }
            return left < right
        }
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        return a.id < b.id
    }

    /// `tagIDs` as the tags this client knows, in display order. An unknown id
    /// is dropped: a tag deleted elsewhere is not followed by per-conversation
    /// updates, so a summary can still name it — and it must neither be drawn
    /// nor counted toward a "+N".
    static func resolve(_ tagIDs: [Int], in byID: [Int: ConversationTag]) -> [ConversationTag] {
        guard !tagIDs.isEmpty else { return [] }
        return tagIDs.compactMap { byID[$0] }.sorted(by: precedes)
    }

    /// A case-insensitive name match within one scope — the server's
    /// uniqueness rule, so the picker offers no create it would refuse.
    static func find(named name: String, scope: Int?, in tags: [ConversationTag]) -> ConversationTag? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return tags.first { $0.folderId == scope && $0.name.lowercased() == key }
    }

    /// The chip a conversation's branch makes, when the branch tag is on and
    /// it has one. Never on a sub-session: its parent row carries it.
    static func branchChip(for conversation: ConversationSummary, enabled: Bool) -> String? {
        guard enabled, conversation.canCarryTags,
              let branch = conversation.gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else { return nil }
        return branch
    }
}

/// Re-ordering one scope's tags in the manager: a drag (`.onMove`) or a
/// Move Up / Move Down. Either way the scope's complete new order is what goes
/// to the server. Pure, for tests.
enum TagOrder {
    /// `items` after a drag: the ones at `source` (offsets into `items`) land,
    /// in their order, just before the one that was at `destination` —
    /// `items.count` being the end — which is how `.onMove` reports a drop
    /// (SwiftUI's `move(fromOffsets:toOffset:)`). Offsets out of range are
    /// ignored and the destination is clamped. Nil when the order comes out
    /// unchanged (a drop in place), so nothing is sent.
    static func moving<T: Equatable>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T]? {
        let picked = source.filter { items.indices.contains($0) }
        guard !picked.isEmpty else { return nil }
        let moved = picked.map { items[$0] }
        var rest = items.indices.filter { !source.contains($0) }.map { items[$0] }
        let clamped = min(max(destination, 0), items.count)
        let insertAt = clamped - picked.filter { $0 < clamped }.count
        rest.insert(contentsOf: moved, at: insertAt)
        return rest == items ? nil : rest
    }

    /// `items` with `item` one place up (`offset` -1) or down (+1). Nil at
    /// the edge it would leave, or for an item not in `items`.
    static func shifting<T: Equatable>(_ items: [T], _ item: T, by offset: Int) -> [T]? {
        guard let from = items.firstIndex(of: item) else { return nil }
        let to = from + offset
        guard to != from, items.indices.contains(to) else { return nil }
        var next = items
        next.insert(next.remove(at: from), at: to)
        return next
    }
}

/// `any`: a conversation matches with at least one selected tag; `all`: only
/// with every one.
enum TagFilterMode: String, Codable, CaseIterable, Hashable, Sendable {
    case matchAny = "any"
    case matchAll = "all"
}

/// The Chats list's tag filter (web `TagFilter`), kept per server — tag ids are
/// a server's own.
struct TagFilter: Codable, Hashable, Sendable {
    /// In the order they were picked.
    var tagIDs: [Int] = []
    var mode: TagFilterMode = .matchAny

    private enum CodingKeys: String, CodingKey {
        case tagIDs = "tagIds"
        case mode
    }

    static let none = TagFilter()

    var isActive: Bool { !tagIDs.isEmpty }

    /// Whether `conversation` passes. An inactive filter passes everything.
    func matches(_ conversation: ConversationSummary) -> Bool {
        guard !tagIDs.isEmpty else { return true }
        let own = conversation.tagIds
        guard !own.isEmpty else { return false }
        switch mode {
        case .matchAll: return tagIDs.allSatisfy(own.contains)
        case .matchAny: return tagIDs.contains(where: own.contains)
        }
    }

    /// Toggle one tag, keeping the order picked.
    func toggling(_ tagID: Int) -> TagFilter {
        var next = self
        if let index = next.tagIDs.firstIndex(of: tagID) {
            next.tagIDs.remove(at: index)
        } else {
            next.tagIDs.append(tagID)
        }
        return next
    }

    /// Only tags that still exist. The filter outlives its tags — it is saved,
    /// and a tag can be deleted elsewhere — and a dead id would turn `all` into
    /// "nothing matches" for no visible reason. Unchanged (`==` self) when
    /// nothing was dropped.
    func pruned(known: Set<Int>) -> TagFilter {
        let kept = tagIDs.filter(known.contains)
        guard kept.count != tagIDs.count else { return self }
        var next = self
        next.tagIDs = kept
        return next
    }
}

/// A tag's chip colours for both themes — web `labelSwatch`, which is GitHub's
/// label treatment (Primer `.IssueLabel`) computed up front: in light, the
/// colour itself as the fill, black or white text by perceived lightness, and a
/// darker rim only for the near-white; in dark, the colour at 18% as the fill
/// with the colour itself lifted for the text. ARGB, for tests and for
/// ``SwiftUI/Color``. Pure.
struct TagSwatch: Equatable, Sendable {
    let background: UInt32
    let foreground: UInt32
    let border: UInt32

    private static let lightTextThreshold = 0.453
    private static let darkTextThreshold = 0.6
    private static let lightBorderThreshold = 0.96
    private static let darkBackgroundAlpha = 0.18
    private static let darkBorderAlpha = 0.3

    /// Nil for a colour that isn't `#rrggbb` — the neutral chip then, rather
    /// than some invented default.
    static func make(_ color: String, dark: Bool) -> TagSwatch? {
        let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#"), trimmed.count == 7,
              trimmed.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let n = UInt32(trimmed.dropFirst(), radix: 16) else { return nil }
        let r = Int((n >> 16) & 0xff), g = Int((n >> 8) & 0xff), b = Int(n & 0xff)
        let hsl = toHSL(r, g, b)
        let (h, s, l) = (round1(hsl.h), round1(hsl.s), round1(hsl.l))
        // ITU-R BT.709 weights, as Primer uses.
        let perceived = (Double(r) * 0.2126 + Double(g) * 0.7152 + Double(b) * 0.0722) / 255
        if !dark {
            // Near-white labels only: elsewhere the fill already separates the
            // chip from the page.
            let borderAlpha = round1(clamp((perceived - lightBorderThreshold) * 100, 0, 1))
            return TagSwatch(
                background: argb(1, r, g, b),
                foreground: perceived < lightTextThreshold ? 0xFFFF_FFFF : 0xFF00_0000,
                border: hslARGB(h, s, round1(clamp(l - 25, 0, 100)), alpha: borderAlpha)
            )
        }
        // Lift the text off the floor by however far the colour sits below the
        // threshold; a colour already light enough is left alone.
        let lift = perceived < darkTextThreshold ? (darkTextThreshold - perceived) * 100 : 0
        let textL = round1(clamp(l + lift, 0, 100))
        return TagSwatch(
            background: argb(darkBackgroundAlpha, r, g, b),
            foreground: hslARGB(h, s, textL, alpha: 1),
            border: hslARGB(h, s, textL, alpha: darkBorderAlpha)
        )
    }

    /// Hue in degrees, saturation and lightness in percent.
    private static func toHSL(_ r: Int, _ g: Int, _ b: Int) -> (h: Double, s: Double, l: Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
        let l = (maxC + minC) / 2
        let span = maxC - minC
        if span == 0 { return (0, 0, l * 100) }
        let s = span / (1 - abs(2 * l - 1))
        let h: Double
        if maxC == rf {
            h = ((gf - bf) / span).truncatingRemainder(dividingBy: 6)
        } else if maxC == gf {
            h = (bf - rf) / span + 2
        } else {
            h = (rf - gf) / span + 4
        }
        let degrees = ((h * 60).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return (degrees, s * 100, l * 100)
    }

    private static func hslARGB(_ h: Double, _ sPct: Double, _ lPct: Double, alpha: Double) -> UInt32 {
        let s = sPct / 100, l = lPct / 100
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let rgb: (r: Double, g: Double, b: Double)
        switch h {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func byte(_ v: Double) -> Int { Int(((v + m) * 255).rounded()) }
        return argb(alpha, byte(rgb.r), byte(rgb.g), byte(rgb.b))
    }

    private static func argb(_ alpha: Double, _ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        func channel(_ v: Int) -> UInt32 { UInt32(Swift.max(0, Swift.min(255, v))) }
        let a = UInt32(Swift.max(0, Swift.min(255, Int((alpha * 255).rounded()))))
        return (a << 24) | (channel(r) << 16) | (channel(g) << 8) | channel(b)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, v)) }

    /// The web trims HSL to one decimal before using it; so does this, so both
    /// clients land on the same colours.
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
