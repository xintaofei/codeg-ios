import SwiftUI

/// A codex Plan-mode `<proposed_plan>` document (web `ProposedPlanPart` →
/// `PlanMarkdownCard`): free-form plan markdown in the plan card's chrome —
/// the same surface, hairline and header type `LivePlanView` uses — so a
/// proposed plan reads as a plan, not as prose.
///
/// Plans are often long enough to bury the rest of the reply, so the body is
/// clamped and gets a Show more / Show less footer once it is actually
/// clipped (web: `max-h-72` + `useCollapsibleOverflow`). An open block that
/// has produced no markdown yet says so instead of drawing bare chrome.
struct ProposedPlanCard: View {
    let markdown: String
    /// The block is still open and its reply still streams.
    var streaming: Bool = false

    /// Show more, kept across the list recycling the row.
    @DisclosureChoice("plan.more") private var choice: Bool?
    private var expanded: Bool { choice ?? false }
    /// The body's natural height, measured unclamped.
    @State private var contentHeight: CGFloat = 0

    /// web `max-h-72`: 18rem.
    private static let clampHeight: CGFloat = 288

    private var overflowing: Bool { contentHeight > Self.clampHeight }
    private var clipped: Bool { overflowing && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
            if overflowing {
                Divider().overlay(Theme.hairline)
                toggle
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Proposed plan")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if streaming {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        Group {
            if markdown.isEmpty {
                Text("Planning…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownContent(raw: markdown, streaming: streaming)
            }
        }
        // Measured at its natural height whatever the clamp offers it, so
        // "is it clipped" never depends on whether it is clipped.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: clipped ? Self.clampHeight : nil, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            if clipped {
                LinearGradient(colors: [Theme.surface.opacity(0), Theme.surface],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var toggle: some View {
        Button {
            withAnimation(Theme.Motion.expand) { choice = !expanded }
        } label: {
            HStack(spacing: 4) {
                expanded ? Text("Show less") : Text("Show more")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Prose that holds `<proposed_plan>` blocks, drawn in order: its prose as
/// markdown, each block as a `ProposedPlanCard`. The live text leaf uses this
/// for the run it is reading (settled prose is split upstream instead).
struct ProposedPlanSegmentsView: View {
    let segments: [ProposedPlan.Segment]
    /// The run is still growing: only its last segment carries the caret.
    var streaming: Bool = false

    var body: some View {
        let lastIndex = segments.count - 1
        VStack(alignment: .leading, spacing: Theme.Typography.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let prose):
                    MarkdownContent(raw: prose, streaming: streaming && index == lastIndex, assistantReply: true)
                case .plan(let markdown, let planStreaming):
                    ProposedPlanCard(markdown: markdown, streaming: planStreaming)
                        .disclosureScope("segment\(index)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
