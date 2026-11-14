import SwiftUI
import UIKit

/// A ```` ```mermaid ```` fence, drawn as a diagram (codeg 0.44 web parity:
/// `mermaid-block.tsx`).
///
/// - **When.** Only once `ready` — the fence closed, or the text stopped
///   streaming. Until then (and while the off-screen renderer works) a
///   placeholder of fixed height holds the space. The web redraws on every
///   streamed delta; this client draws once.
/// - **Inline.** A static picture of the diagram, fitted to the column (never
///   enlarged), at most 60% of the window tall, its clipped edge faded. Tap
///   opens it full screen; long-press copies the source.
/// - **Theme.** Mermaid's `dark` / `default` theme follows the color scheme and
///   is part of the cache key; on a switch the old picture stays until the new
///   one is drawn (the web keeps its last SVG the same way).
/// - **Errors.** "Mermaid error: …" with Retry, and the source behind "Show
///   source". Failures are not cached, so Retry draws again.
///
/// All state is this leaf's own (`@State` + `.task(id:)`); the transcript
/// re-parses streaming text every ~50 ms and the task's id — source, theme and
/// size — does not change across those passes, so nothing is drawn twice.
struct MermaidBlock: View {
    let source: String
    let ready: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.richBlockViewer) private var viewer

    @State private var width: CGFloat = 0
    @State private var shown: Shown?
    @State private var failure: Failure?
    @State private var attempt = 0
    @State private var showSource = false
    @State private var localViewer: RichBlockViewerInput?
    @State private var copyTick = 0
    @Environment(\.transcriptContentGrew) private var contentGrew

    private struct Shown {
        let source: String
        let rendering: MermaidRendering
    }

    private struct Failure: Equatable {
        /// The source + theme it failed for.
        let key: String
        /// Mermaid's message; nil when the renderer itself failed.
        let message: String?
    }

    private struct LoadID: Equatable {
        let request: WebRenderHost.MermaidRequest?
        let attempt: Int
    }

    static let placeholderHeight: CGFloat = 112
    /// Between the card's edge and the picture.
    private static let inset: CGFloat = 8
    private static let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)

    var body: some View {
        let theme = MermaidTheme(dark: colorScheme == .dark)
        let request = makeRequest(theme: theme)
        content(request: request, theme: theme)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: LoadID(request: ready ? request : nil, attempt: attempt)) {
                await load(ready ? request : nil)
            }
            .richBlockViewerFallback($localViewer)
            .sensoryFeedback(.success, trigger: copyTick)
    }

    /// The picture this block asks for: the column inside the card, capped at
    /// 60% of the window's height. Nil until the column has been measured.
    private func makeRequest(theme: MermaidTheme) -> WebRenderHost.MermaidRequest? {
        let column = (width - 2 * Self.inset).rounded(.down)
        guard column > 0 else { return nil }
        return WebRenderHost.MermaidRequest(source: source, theme: theme, width: column,
                                            maxHeight: Self.maxPictureHeight)
    }

    /// The web's `max-h-[60vh]`.
    private static var maxPictureHeight: CGFloat {
        let window = OffscreenParking.activeWindow()?.bounds.height ?? 800
        return max(200, (window * 0.6).rounded())
    }

    @ViewBuilder
    private func content(request: WebRenderHost.MermaidRequest?, theme: MermaidTheme) -> some View {
        if !ready {
            placeholder
        } else if let rendering = displayed(request: request, theme: theme) {
            diagram(rendering)
        } else if let failure, failure.key == WebRenderKey.mermaid(source: source, theme: theme) {
            errorCard(failure.message)
        } else {
            placeholder
        }
    }

    /// The picture for exactly this request; else, while it is drawn, the last
    /// one of this source (another theme or width) — this block's own, or one
    /// the renderer still holds (a row re-created as a reply settles).
    private func displayed(request: WebRenderHost.MermaidRequest?, theme: MermaidTheme) -> MermaidRendering? {
        let host = WebRenderHost.shared
        if let request, let exact = host.cachedMermaid(request) { return exact }
        if let shown, shown.source == source { return shown.rendering }
        return host.latestMermaid(source: source, theme: theme)
    }

    private func load(_ request: WebRenderHost.MermaidRequest?) async {
        guard let request else { return }
        let host = WebRenderHost.shared
        if let hit = host.cachedMermaid(request) {
            show(hit)
            return
        }
        do {
            let rendering = try await host.mermaid(request)
            guard !Task.isCancelled else { return }
            show(rendering)
        } catch {
            guard !Task.isCancelled else { return }
            if case WebRenderError.mermaid(let message) = error, !message.isEmpty {
                failure = Failure(key: request.diagramKey, message: message)
            } else {
                failure = Failure(key: request.diagramKey, message: nil)
            }
            contentGrew()
        }
    }

    private func show(_ rendering: MermaidRendering) {
        shown = Shown(source: source, rendering: rendering)
        failure = nil
        contentGrew()
    }

    private func open(_ rendering: MermaidRendering) {
        let input = RichBlockViewerInput(content: .mermaid(MermaidViewerContent(
            source: source, diagram: rendering.diagram, theme: rendering.theme, preview: rendering.image)))
        if let viewer {
            viewer.input = input
        } else {
            localViewer = input
        }
    }

    // MARK: States

    private func diagram(_ rendering: MermaidRendering) -> some View {
        let column = max(1, width - 2 * Self.inset)
        let fit = min(1, column / max(rendering.size.width, 1))
        let size = CGSize(width: (rendering.size.width * fit).rounded(.down),
                          height: (rendering.size.height * fit).rounded(.down))
        let surface = RichBlockPalette(dark: rendering.theme.dark).color
        return Button {
            open(rendering)
        } label: {
            Image(uiImage: rendering.image)
                .resizable()
                .interpolation(.high)
                .frame(width: max(1, size.width), height: max(1, size.height))
                .overlay(alignment: .bottom) {
                    if rendering.clipped {
                        // The cap cuts a tall diagram mid-stroke: fade the edge
                        // so it reads as "there is more", not as a fault.
                        LinearGradient(colors: [surface.opacity(0), surface],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(Self.inset)
                .background(surface, in: Self.shape)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(6)
                        .background(Theme.surface, in: Circle())
                        .padding(6)
                        .accessibilityHidden(true)
                }
                .hairlineBorder(Theme.Radius.sm)
                .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = source
                copyTick &+= 1
            } label: {
                Label("Copy source", systemImage: "doc.on.doc")
            }
            Button {
                open(rendering)
            } label: {
                Label("View fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .accessibilityLabel(Text("Diagram"))
        .accessibilityAddTraits(.isImage)
        .accessibilityHint(Text("View fullscreen"))
    }

    private var placeholder: some View {
        Text("Rendering diagram…")
            .font(.subheadline)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: Self.placeholderHeight)
            .background(RichBlockPalette.card, in: Self.shape)
            .hairlineBorder(Theme.Radius.sm)
            .accessibilityElement(children: .combine)
    }

    private func errorCard(_ message: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if let message {
                        Text("Mermaid error: \(message)")
                    } else {
                        Text("Mermaid error: \(Text("Failed to render diagram"))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Retry") {
                    failure = nil
                    attempt += 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                withAnimation(Theme.Motion.expand) { showSource.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showSource ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Show source")
                        .font(.caption)
                }
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showSource ? Text("Expanded") : Text("Collapsed"))

            if showSource {
                CodeBlockView(code: source, language: "mermaid")
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.06), in: Self.shape)
        .overlay(Self.shape.strokeBorder(Theme.danger.opacity(0.3), lineWidth: 0.75))
    }
}
