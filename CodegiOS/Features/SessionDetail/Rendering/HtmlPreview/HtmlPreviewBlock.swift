import SwiftUI
import UIKit

/// A closed ```` ```html ```` / ```` ```htm ```` fence in an assistant reply,
/// with "Render HTML in chat" on (codeg 0.44 web parity: `html-code-preview.tsx`).
///
/// - A Code / Preview switch, Preview first; the choice (and "Show all") is
///   remembered per source, so the block comes back as it was when a reply
///   settles into a new row.
/// - **Preview** is a static picture of the sanitized document laid out at the
///   column's width (`ChatHtmlDocument`, drawn off-screen by `WebRenderHost`
///   with content JavaScript off and every network load blocked). The
///   document's height is clamped to 96–12,000 points; 160 holds the space
///   while it is drawn; past 640 it is cut until "Show all". Tap opens the live
///   document full screen — still no script, no network — where `<details>`
///   open and the page scrolls.
/// - The theme (scheme + accent) is part of the cache key. A preview that
///   cannot be drawn falls back to the code, as the web's does.
///
/// State is this leaf's own (`@State` + `.task(id:)`).
struct HtmlPreviewBlock: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme
    /// The accent straight from the store: the bridged accent trait behind
    /// `\.codegAccent` doesn't reach a transcript shown in a sheet.
    @Environment(AppearanceStore.self) private var appearance: AppearanceStore?
    @Environment(\.codegAccent) private var bridgedAccent
    @Environment(\.richBlockViewer) private var viewer

    @State private var preview: Bool
    @State private var expanded: Bool
    @State private var width: CGFloat = 0
    @State private var shown: Shown?
    @State private var failedKey: String?
    @State private var localViewer: RichBlockViewerInput?
    @Environment(\.transcriptContentGrew) private var contentGrew
    /// Off once the reader switches the view or its height: the picture that
    /// lands for their own choice must not move the transcript under them.
    @State private var followsGrowth = true

    private struct Shown {
        let source: String
        let rendering: HtmlRendering
    }

    private enum Mode: Hashable {
        case code, preview
    }

    private static let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)

    init(source: String) {
        self.source = source
        let remembered = HtmlPreviewViewMemory.shared.choice(for: source)
        _preview = State(initialValue: remembered.preview)
        _expanded = State(initialValue: remembered.expanded)
    }

    var body: some View {
        let theme = ChatHtmlTheme(dark: colorScheme == .dark, accent: appearance?.accent ?? bridgedAccent)
        let request = makeRequest(theme: theme, expanded: expanded)
        VStack(alignment: .leading, spacing: 8) {
            header
            if preview {
                previewBody(request: request, theme: theme)
            } else {
                CodeBlockView(code: source, language: "html")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: preview ? request : nil) {
            await load(preview ? request : nil)
        }
        .richBlockViewerFallback($localViewer)
    }

    private func makeRequest(theme: ChatHtmlTheme, expanded: Bool) -> WebRenderHost.HtmlRequest? {
        let column = width.rounded(.down)
        guard column > 0 else { return nil }
        return WebRenderHost.HtmlRequest(source: source, theme: theme, width: column,
                                         clip: HtmlPreviewMetrics.pictureClip(expanded: expanded))
    }

    private func remember() {
        HtmlPreviewViewMemory.shared.remember(.init(preview: preview, expanded: expanded), for: source)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text("HTML preview")
            } icon: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .labelStyle(.titleAndIcon)
            .font(Theme.Typography.metaLabel)
            .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Picker("HTML preview", selection: Binding(
                get: { preview ? Mode.preview : Mode.code },
                set: { mode in
                    followsGrowth = false
                    preview = mode == .preview
                    remember()
                }
            )) {
                Text("Code").tag(Mode.code)
                Text("Preview").tag(Mode.preview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func previewBody(request: WebRenderHost.HtmlRequest?, theme: ChatHtmlTheme) -> some View {
        if let rendering = displayed(request: request, theme: theme) {
            picture(rendering)
        } else if failedKey == WebRenderKey.htmlDocument(source: source, theme: theme) {
            CodeBlockView(code: source, language: "html")
        } else {
            placeholder
        }
    }

    /// The picture for exactly this request; else, while it is drawn, the
    /// other view's picture at this width (collapsed ↔ all), or the last one
    /// this block showed of this source.
    private func displayed(request: WebRenderHost.HtmlRequest?, theme: ChatHtmlTheme) -> HtmlRendering? {
        let host = WebRenderHost.shared
        if let request {
            if let exact = host.cachedHtml(request) { return exact }
            let other = WebRenderHost.HtmlRequest(source: source, theme: theme, width: request.width,
                                                  clip: HtmlPreviewMetrics.pictureClip(expanded: !expanded))
            if let near = host.cachedHtml(other) { return near }
        }
        if let shown, shown.source == source { return shown.rendering }
        return nil
    }

    private func load(_ request: WebRenderHost.HtmlRequest?) async {
        guard let request else { return }
        let host = WebRenderHost.shared
        if let hit = host.cachedHtml(request) {
            show(hit)
            return
        }
        // The other view's picture may already cover this one: the full
        // document holds its first 640 points, and a short document's
        // collapsed picture is the whole of it.
        let otherClip = request.clip == HtmlPreviewMetrics.collapsedHeight
            ? HtmlPreviewMetrics.maxHeight : HtmlPreviewMetrics.collapsedHeight
        let other = WebRenderHost.HtmlRequest(source: request.source, theme: request.theme,
                                              width: request.width, clip: otherClip)
        if let near = host.cachedHtml(other), near.covered >= min(near.height, request.clip) {
            show(near)
            return
        }
        do {
            let rendering = try await host.html(request)
            guard !Task.isCancelled else { return }
            show(rendering)
        } catch {
            guard !Task.isCancelled else { return }
            failedKey = WebRenderKey.htmlDocument(source: request.source, theme: request.theme)
            if followsGrowth { contentGrew() }
        }
    }

    private func show(_ rendering: HtmlRendering) {
        shown = Shown(source: source, rendering: rendering)
        failedKey = nil
        if followsGrowth { contentGrew() }
    }

    private func picture(_ rendering: HtmlRendering) -> some View {
        // Drawn for another width (a rotation in progress): scale to fit.
        let fit = width > 0 ? min(1, width / max(rendering.width, 1)) : 1
        let visible = min(HtmlPreviewMetrics.visibleHeight(rendering.height, expanded: expanded), rendering.covered)
        let drawingMore = expanded && rendering.covered < rendering.height
        let surface = RichBlockPalette(dark: rendering.theme.dark).color
        return VStack(spacing: 0) {
            Button {
                open(rendering)
            } label: {
                Image(uiImage: rendering.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rendering.width * fit, height: rendering.covered * fit)
                    .frame(height: visible * fit, alignment: .top)
                    .clipped()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface)
                    .clipShape(Self.shape)
                    .hairlineBorder(Theme.Radius.sm)
                    .contentShape(Self.shape)
                    .overlay(alignment: .bottom) {
                        if drawingMore {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("HTML preview"))
            .accessibilityAddTraits(.isImage)
            .accessibilityHint(Text("View fullscreen"))

            if HtmlPreviewMetrics.overflows(rendering.height) {
                Button {
                    followsGrowth = false
                    withAnimation(Theme.Motion.expand) { expanded.toggle() }
                    remember()
                } label: {
                    (expanded ? Text("Collapse") : Text("Show all"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var placeholder: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: HtmlPreviewMetrics.placeholderHeight)
            .background(RichBlockPalette.card, in: Self.shape)
            .hairlineBorder(Theme.Radius.sm)
            .accessibilityLabel(Text("HTML preview"))
    }

    private func open(_ rendering: HtmlRendering) {
        let input = RichBlockViewerInput(content: .html(HtmlViewerContent(source: source, theme: rendering.theme)))
        if let viewer {
            viewer.input = input
        } else {
            localViewer = input
        }
    }
}

// MARK: - Viewer

struct HtmlViewerContent {
    let source: String
    let theme: ChatHtmlTheme
}

/// The preview full screen: the same sanitized document, live — scrolling,
/// zooming, `<details>` — with content JavaScript still off and every network
/// load still blocked.
struct HtmlPreviewViewer: View {
    let content: HtmlViewerContent

    @Environment(\.dismiss) private var dismiss
    @State private var document: String?

    var body: some View {
        let palette = RichBlockPalette(dark: content.theme.dark)
        NavigationStack {
            Group {
                if let document {
                    SandboxedWebView(html: document, background: palette.uiColor)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(palette.color.ignoresSafeArea())
            .navigationTitle(Text("HTML preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        .modifier(ResolvedAccent())
        .task {
            let source = content.source
            let theme = content.theme
            document = await Task.detached(priority: .userInitiated) {
                ChatHtmlDocument.build(source: source, theme: theme)
            }.value
        }
    }
}
