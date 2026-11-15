import SwiftUI

// MARK: - Marker alignment

extension VerticalAlignment {
    /// The line the timeline uses to line a node's marker up with the *head* of
    /// its content (the first line of prose, or a card's title row) rather than
    /// the geometric middle of a tall row. The default resolves to the first text
    /// baseline, so most node bodies need no explicit guide — text and card
    /// headers publish their baseline automatically, which keeps the marker
    /// correctly placed across Dynamic Type sizes. Bodies without leading text
    /// (an image, the pre-token shimmer) opt into a top-relative anchor via
    /// `railHead(_:)`.
    private enum RailMarkerID: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.firstTextBaseline] }
    }
    static let railMarker = VerticalAlignment(RailMarkerID.self)
}

/// Where a node body wants its rail marker to sit. `firstLine` is the default
/// (baseline-tracked); `top(_:)` pins the marker a fixed distance below the
/// body's top for content with no leading text.
enum RailHead {
    case firstLine
    case top(CGFloat)
}

extension View {
    /// Override the rail-marker anchor for this node body. Most bodies don't need
    /// this (the default first-baseline anchor is correct); use it for textless
    /// content so the marker doesn't fall to the body's bottom.
    func railHead(_ head: RailHead) -> some View {
        alignmentGuide(.railMarker) { d in
            switch head {
            case .firstLine: return d[.firstTextBaseline]
            case .top(let inset): return d[VerticalAlignment.top] + inset
            }
        }
    }
}

// MARK: - Metrics

/// Geometry for the transcript timeline. `gutterWidth` and the marker sizes are
/// scaled with Dynamic Type at the call site (`@ScaledMetric`); the rest are
/// fixed structural values. `rowSpacing` reproduces the old transcript's
/// `listRowInsets` vertical rhythm (9 + 9 between adjacent rows) so the
/// bottom-proximity / auto-follow math in `TranscriptView` behaves identically.
enum TimelineMetrics {
    static let gutterWidth: CGFloat = 30
    /// Trailing inset = the standard 16pt layout margin. Content's right edge lands
    /// here, matching the nav bar's trailing button's outer edge.
    static let rowTrailingInset: CGFloat = 16
    /// Leading inset, chosen so the marker's *left edge* lands on that same 16pt
    /// layout margin — mirroring the right side, where the content edge aligns with
    /// the nav bar's leading button outer edge (both at 16pt). The marker is
    /// centered in `gutterWidth`, so its left edge sits `(gutterWidth - markerSize)/2`
    /// in from the gutter; we pull the gutter left by that amount: 16 − (30−26)/2 = 13.
    static let rowLeadingInset: CGFloat = rowTrailingInset - (gutterWidth - markerSize) / 2
    static let lineWidth: CGFloat = 1.5
    static let rowSpacing: CGFloat = 18
    static let gutterContentGap: CGFloat = 10
    /// Extra breathing room added *above* a node that starts a new turn (a user /
    /// system node), kept inside the rail-drawn region so the spine stays unbroken.
    static let groupGap: CGFloat = 10
    /// All disc markers share one diameter so every marker's left edge lines up
    /// (a smaller non-user marker would sit a point inward of the user marker) and
    /// the non-user icons don't read as undersized next to the user/agent ones.
    static let markerSize: CGFloat = 26
    static let userMarkerSize: CGFloat = 26
    /// Nudge the marker's center above the text baseline so it sits on the line's
    /// optical center rather than its descender baseline.
    static let baselineNudge: CGFloat = 5
    /// Clearance between a marker's edge and where the spine resumes, so the line
    /// never runs under an icon — there's a small blank gap above and below each.
    static let markerGap: CGFloat = 4
    /// How far each spine segment overdraws past its row edge so adjacent rows'
    /// segments overlap into one unbroken line. Kept tiny: just enough to defeat the
    /// sub-pixel seam a butt-joint shows in a `List` at ×2 / ×3, without the visibly
    /// darker stub a larger overlap leaves (two semi-transparent segments stacking).
    static let spineOverdraw: CGFloat = 1
}

// MARK: - Row

/// One row of the timeline: a fixed-width gutter holding the node's state marker,
/// the node body to its right, and — drawn behind both — the continuous vertical
/// spine. The spine is drawn in the row background from the marker's *resolved*
/// centre (read via an anchor preference) up to the row's top edge and down to its
/// bottom edge, so consecutive rows compose one unbroken rail at any content height
/// while still giving each node independent control of whether the rail continues
/// above (`connectTop`) and below (`connectBottom`) it (suppressed at the very
/// first / last node).
struct TimelineRailRow<Body: View>: View {
    let marker: MarkerKind
    let connectTop: Bool
    let connectBottom: Bool
    var startsGroup: Bool = false
    @ViewBuilder var content: () -> Body

    @ScaledMetric(relativeTo: .body) private var gutter = TimelineMetrics.gutterWidth
    @ScaledMetric(relativeTo: .body) private var markerDim = TimelineMetrics.markerSize

    /// Clamp the scaled gutter so very large Dynamic Type sizes don't push the
    /// content column uselessly narrow on a phone.
    private var gutterWidth: CGFloat { min(gutter, TimelineMetrics.gutterWidth * 1.6) }
    private var markerSize: CGFloat { min(markerDim, TimelineMetrics.markerSize * 1.5) }

    /// Whether the spine runs *through* this marker rather than breaking around
    /// it. Only the small system/footer ticks do — they're opaque dots meant to
    /// sit *on* the line as a small node at a turn boundary, so the rail reads as
    /// continuous through them. Every glyph marker breaks the spine around itself.
    private var spineRunsThrough: Bool {
        switch marker {
        case .system, .footer, .compaction: return true
        default:                            return false
        }
    }

    var body: some View {
        HStack(alignment: .railMarker, spacing: TimelineMetrics.gutterContentGap) {
            NodeMarker(kind: marker)
                .frame(width: gutterWidth)
                .alignmentGuide(.railMarker) { d in d[VerticalAlignment.center] + TimelineMetrics.baselineNudge }
                // Publish the marker's resolved centre so the background rail can
                // break exactly there — at any content height (see `rail`).
                .anchorPreference(key: MarkerCenterKey.self, value: .center) { $0 }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, TimelineMetrics.rowSpacing / 2 + (startsGroup ? TimelineMetrics.groupGap : 0))
        .padding(.bottom, TimelineMetrics.rowSpacing / 2)
        // The rail is drawn as the row background (so it never affects row sizing).
        // The marker glyph (in the HStack, in front of the background) sits in the
        // gap where the spine stops short of it; the break is made by shortening
        // the spine halves around the marker centre (see `rail`), not by painting
        // an opaque disc over the line — so the real backdrop shows around the icon.
        .backgroundPreferenceValue(MarkerCenterKey.self) { anchor in
            rail(markerAnchor: anchor)
        }
    }

    /// The vertical rail for this row, drawn behind the gutter. The marker's resolved
    /// centre — read from the anchor preference in *this row's* coordinate space — is
    /// where the line breaks, so the two halves always reach the row's top and bottom
    /// edges no matter how tall the content is. (The earlier design split a single
    /// height-filling stack with alignment guides; on a tall row the `.background`
    /// frame was dragged off the row and its bottom half stopped halfway down — a long
    /// blank gap below the node — while the top half ran through the icon above.
    /// Drawing from the marker's *actual* position sidesteps that entirely.) Each half
    /// overshoots its row edge by a hair so adjacent rows overlap into one seamless
    /// spine; the clean break *around* the icon is the `gap` each half stops short
    /// by, leaving the real backdrop visible there instead of a painted disc.
    /// `connectTop` / `connectBottom` drop a half to terminate the rail at the very
    /// first / last node.
    private func rail(markerAnchor: Anchor<CGPoint>?) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let cx = gutterWidth / 2
            // Marker centre in this background's space; fall back to the row centre
            // if the preference hasn't resolved yet (first layout pass).
            let my = markerAnchor.map { geo[$0].y } ?? h / 2
            let over = TimelineMetrics.spineOverdraw
            // Break the spine *around* the marker by stopping each half short of
            // it, leaving the real backdrop (the `CodegBackground` gradient + its
            // soft glows) showing through the gap. Drawing an opaque `Theme.bg`
            // disc here instead — the previous approach — painted flat near-white
            // over that gradient and read as a pale halo ring around every icon.
            // The system/footer ticks are opaque dots meant to sit on the line, so
            // there the spine runs all the way through (gap 0) and the dot covers
            // the crossing, keeping the rail continuous across a turn boundary.
            let gap = spineRunsThrough ? 0 : markerSize / 2 + TimelineMetrics.markerGap
            ZStack {
                if connectTop {
                    railLine(from: -over, to: my - gap, x: cx)
                }
                if connectBottom {
                    railLine(from: my + gap, to: h + over, x: cx)
                }
            }
        }
    }

    /// A single vertical hairline of the rail between two y-positions in the row's
    /// coordinate space.
    private func railLine(from y0: CGFloat, to y1: CGFloat, x: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: x, y: y0))
            p.addLine(to: CGPoint(x: x, y: y1))
        }
        .stroke(Theme.rail, lineWidth: TimelineMetrics.lineWidth)
    }
}

// MARK: - Marker position preference

/// Carries a node marker's centre (as an `Anchor`, resolved in the row's own
/// coordinate space) from the gutter up to the row background, so the rail can
/// break the line exactly at the icon. Reading the marker's real resolved
/// position — rather than splitting a height-filling stack with alignment guides —
/// is what keeps the spine from leaving a blank gap below a tall node or running
/// through the icon above it. One marker per row, so `reduce` keeps the first.
private struct MarkerCenterKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

// MARK: - Marker

/// What a node's gutter marker depicts. Derived from the node's content by the
/// builder; rendered by `NodeMarker`. State (`running`/`done`/`error`) drives the
/// marker tint so the rail is scannable at a glance ("what ran, did it succeed").
enum MarkerKind {
    case user
    /// A reply's header: the session's agent.
    case assistant(AgentType)
    /// The agent's words — a small dot. Agent glyphs stay with the reply's
    /// header and the delegations, so a glyph on the rail always means "an
    /// agent took over here".
    case prose
    /// A delegated task: the logo of the agent that took it, ringed in how
    /// it stands; a resume wears a small replay mark. Resolved against the
    /// live binding as it draws.
    case delegation(ToolCallVM, later: DelegationTaskRow?)
    /// Checks on (or a cancel of) delegated tasks, ringed in how the tasks stand.
    case delegationChecks([ToolCallVM], cancel: Bool)
    case reasoning
    case tool(icon: String, state: ToolCallState)
    case toolGroup(error: Bool, streaming: Bool)
    case image
    case system
    case plan
    case thinking
    case error
    case footer
    /// A context-compaction boundary. Like `.footer` it is a *marker on* the
    /// spine, not an event hanging off it, so the rail runs straight through.
    case compaction
}

/// The gutter marker. Centralizes state tinting, the running pulse, the
/// Reduce-Motion fallback (a static ring), and accessibility (markers are
/// decorative — the node body already conveys type/state — so they're hidden
/// from VoiceOver to avoid announcing a dot before every message).
struct NodeMarker: View {
    let kind: MarkerKind

    @ScaledMetric(relativeTo: .body) private var scaledSize = TimelineMetrics.markerSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activityLive) private var live

    private var size: CGFloat { min(scaledSize, TimelineMetrics.markerSize * 1.5) }

    var body: some View {
        marker
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var marker: some View {
        switch kind {
        case .user:
            chip(icon: "person.fill", tint: Theme.accent, filled: true, scale: TimelineMetrics.userMarkerSize / TimelineMetrics.markerSize)
        case .assistant(let agent):
            AgentAvatar(agent: agent, size: size)
        case .prose:
            Circle()
                .fill(Theme.textTertiary.opacity(0.75))
                .frame(width: size * 0.28, height: size * 0.28)
        case .delegation(let vm, let later):
            delegationMarker(vm, later: later)
        case .delegationChecks(let polls, let cancel):
            checksMarker(polls, cancel: cancel)
        case .reasoning:
            chip(icon: "brain", tint: Theme.textTertiary)
        case .tool(let icon, let state):
            toolMarker(icon: icon, state: state)
        case .toolGroup(let error, let streaming):
            ZStack {
                chip(icon: "square.stack.3d.up.fill", tint: error ? Theme.danger : Theme.accent)
                if streaming { pulseRing(tint: Theme.accent) }
            }
        case .image:
            chip(icon: "photo", tint: Theme.textSecondary)
        case .system:
            Circle()
                .fill(Theme.textTertiary)
                .frame(width: size * 0.36, height: size * 0.36)
        case .plan:
            chip(icon: "checklist", tint: Theme.accent)
        case .thinking:
            // Calm grey (matching the body's `ThinkingShimmer`) — "thinking" has
            // made no commitment yet, so it reads quieter than an active accent
            // tool marker, and the live turn shows one fewer competing accent pulse.
            ZStack {
                chip(icon: "ellipsis", tint: Theme.textSecondary)
                pulseRing(tint: Theme.textTertiary)
            }
        case .error:
            chip(icon: "exclamationmark", tint: Theme.danger, filled: true)
        case .footer:
            // A small solid tick sitting *on* the spine (which runs through it, not
            // around), so the rail reads as continuous through a turn boundary
            // rather than broken.
            Circle()
                .fill(Theme.rail)
                .frame(width: size * 0.42, height: size * 0.42)
        case .compaction:
            // The divider body already carries the archive glyph and the label;
            // the gutter just marks the point on the spine.
            Circle()
                .fill(Theme.rail)
                .frame(width: size * 0.42, height: size * 0.42)
        }
    }

    @ViewBuilder
    private func toolMarker(icon: String, state: ToolCallState) -> some View {
        let tint: Color = {
            switch state {
            case .running, .inputStreaming: return Theme.accent
            case .done: return DiffPalette.addText
            case .error: return Theme.danger
            }
        }()
        ZStack {
            chip(icon: icon, tint: tint)
            if state == .running || state == .inputStreaming {
                pulseRing(tint: tint)
            }
        }
    }

    @ViewBuilder
    private func delegationMarker(_ vm: ToolCallVM, later: DelegationTaskRow?) -> some View {
        if let card = live.delegationCard(vm, later: later) {
            // The call a permission request waits on is the user's to answer.
            let awaiting = (vm.state == .running || vm.state == .inputStreaming) && live.awaitingToolCallId == vm.id
            let tint = awaiting ? Theme.warning : DelegationTint.of(card.status)
            ZStack {
                DelegationRailGlyph(agent: card.agentType, tint: tint, size: size, resumed: card.resumed)
                if card.working, !awaiting { pulseRing(tint: tint) }
            }
        } else {
            toolMarker(icon: vm.icon, state: vm.state)
        }
    }

    private func checksMarker(_ polls: [ToolCallVM], cancel: Bool) -> some View {
        let status = DelegationModel.checksStatus(polls, kind: cancel ? .cancel : .status)
        let tint = DelegationTint.of(status)
        return ZStack {
            chip(icon: cancel ? "nosign" : "hourglass", tint: tint)
            if status == .running { pulseRing(tint: tint) }
        }
    }

    /// A `SectionBadgeIcon`-style filled disc: tinted glyph on a faint tinted fill
    /// with a hairline ring. `filled` makes it a solid accent/danger disc with an
    /// on-accent glyph (used for the prominent user / error markers).
    private func chip(icon: String, tint: Color, filled: Bool = false, scale: CGFloat = 1) -> some View {
        let d = size * scale
        return Image(systemName: icon)
            .font(.system(size: d * 0.42, weight: .semibold))
            .foregroundStyle(filled ? Theme.onAccent : tint)
            .frame(width: d, height: d)
            .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16)), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(filled ? 0 : 0.34), lineWidth: 1))
    }

    /// An expanding ring that conveys "in progress". Static (a steady ring) under
    /// Reduce Motion so the persistent rail isn't a field of pulsing dots.
    @ViewBuilder
    private func pulseRing(tint: Color) -> some View {
        if reduceMotion {
            Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1.5)
                .frame(width: size, height: size)
        } else {
            PulseRing(tint: tint, size: size)
        }
    }
}

/// The animated half of the running indicator, split out so the `@State`
/// animation flag is owned per-marker and starts cleanly on appear.
private struct PulseRing: View {
    let tint: Color
    let size: CGFloat
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(animate ? 1.75 : 1)
            .opacity(animate ? 0 : 0.7)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
