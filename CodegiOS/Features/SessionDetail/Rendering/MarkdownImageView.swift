import SwiftUI
import UIKit

/// One Markdown image, as a block of its own (codeg 0.44 web parity:
/// `markdown-local-image.tsx` for local files, Streamdown's `<img>` for remote
/// ones).
///
/// - Loads through the transcript's `MarkdownImageLoader`; with none (Markdown
///   outside a transcript) nothing is read and only the label shows.
/// - Draws at the image's natural size, capped to the column width and 384 pt
///   tall, rounded. While it loads, a placeholder of fixed height holds the
///   space (so a reply that is pinned to the bottom doesn't jump twice); when
///   it can't be read, a `photo` badge and the label (alt text, else the file
///   name, else the destination).
/// - Tap opens the full-screen viewer — unless the image is a link's content,
///   when the tap opens the link instead.
///
/// All state is this leaf's own (`@State` + `.task(id:)`): the streaming
/// transcript re-parses every ~50 ms, and the task's id — the image's cache
/// key and decode size — stays the same across those re-parses, so nothing is
/// read twice.
struct MarkdownImageBlock: View {
    let image: MarkdownImageRef

    @Environment(\.markdownImageLoader) private var loader
    @Environment(\.markdownImageViewer) private var viewer
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL

    @State private var shown: Shown?
    @State private var failedKey: String?
    @State private var width: CGFloat = 0
    @State private var copyTick = 0
    @Environment(\.transcriptContentGrew) private var contentGrew

    private struct Shown {
        let key: String
        let decoded: DecodedMarkdownImage
        /// The decode size it was read at; 0 = a cached stand-in kept after a
        /// failed re-read.
        let maxPixel: Int
    }

    private struct LoadID: Equatable {
        let key: String?
        let maxPixel: Int
    }

    static let maxHeight: CGFloat = 384
    private static let placeholderHeight: CGFloat = 120

    var body: some View {
        let target = loader.flatMap { MarkdownImageTarget.resolve(image, root: $0.root) }
        let key = target.flatMap { loader?.key(for: $0) }
        let label = Self.label(alt: image.alt, target: target, source: image.source)
        let budget = decodeBudget

        content(target: target, key: key, label: label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: LoadID(key: key, maxPixel: budget)) {
                await load(target: target, key: key, maxPixel: budget)
            }
            .sensoryFeedback(.success, trigger: copyTick)
    }

    /// `alt || name || source`.
    static func label(alt: String, target: MarkdownImageTarget?, source: String) -> String {
        if !alt.isEmpty { return alt }
        if let name = target?.name, !name.isEmpty { return name }
        return source
    }

    /// Long-side pixels for the feed: the column (or the height cap, whichever
    /// is larger) at screen scale, rounded up to 256 so a small width change
    /// doesn't re-decode. 0 until the column has been measured.
    private var decodeBudget: Int {
        guard width > 0 else { return 0 }
        let points = max(width, Self.maxHeight)
        let pixels = Int((points * max(displayScale, 1)).rounded(.up))
        return (pixels + 255) / 256 * 256
    }

    @ViewBuilder
    private func content(target: MarkdownImageTarget?, key: String?, label: String) -> some View {
        if let loader, let target, let key, !target.isSVG {
            if let shown, shown.key == key {
                picture(shown.decoded, label: label, target: target, loader: loader)
            } else if failedKey == key {
                unavailable(label)
            } else if let cached = loader.cachedImage(for: target) {
                // Re-created (a recycled row, a reply that just settled): show
                // the last decode at once; the task reads it afresh.
                picture(cached, label: label, target: target, loader: loader)
            } else {
                loading(label)
            }
        } else {
            unavailable(label)
        }
    }

    private func load(target: MarkdownImageTarget?, key: String?, maxPixel: Int) async {
        guard let loader, let target, let key, maxPixel > 0, !target.isSVG else { return }
        if let shown, shown.key == key, shown.maxPixel >= maxPixel { return }
        let result = await loader.image(for: target, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        if let result {
            shown = Shown(key: key, decoded: result, maxPixel: maxPixel)
            failedKey = nil
        } else if shown?.key != key {
            // Keep a picture already on screen rather than swapping it for a
            // failure row over one failed re-read.
            if let cached = loader.cachedImage(for: target) {
                shown = Shown(key: key, decoded: cached, maxPixel: 0)
            } else {
                failedKey = key
            }
        }
        contentGrew()
    }

    // MARK: States

    @ViewBuilder
    private func picture(_ decoded: DecodedMarkdownImage, label: String,
                         target: MarkdownImageTarget, loader: MarkdownImageLoader) -> some View {
        let size = fittedSize(decoded.pixelSize)
        let drawn = Image(uiImage: decoded.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

        if let link = image.link {
            Button {
                if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { openURL(url) }
            } label: {
                drawn
            }
            .buttonStyle(.plain)
            .contextMenu { imageActions(decoded.image, label: label) }
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityAddTraits([.isImage, .isLink])
        } else {
            Button {
                viewer?.input = MarkdownImageViewerInput(label: label, initial: decoded, target: target, loader: loader)
            } label: {
                drawn
            }
            .buttonStyle(.plain)
            .contextMenu { imageActions(decoded.image, label: label) }
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityAddTraits(.isImage)
        }
    }

    /// Long-press actions, as the web's image context menu (copy, share in
    /// place of download).
    @ViewBuilder
    private func imageActions(_ image: UIImage, label: String) -> some View {
        Button {
            UIPasteboard.general.image = image
            copyTick &+= 1
        } label: {
            Label("Copy image", systemImage: "doc.on.doc")
        }
        ShareLink(item: Image(uiImage: image), preview: SharePreview(label, image: Image(uiImage: image))) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func loading(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: label)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.placeholderHeight)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
        .accessibilityElement(children: .combine)
    }

    private func unavailable(_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .accessibilityHidden(true)
            Text(verbatim: label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(Theme.textTertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isImage)
    }

    /// Natural size (a pixel per point, as a browser draws it), scaled down to
    /// fit the column and the height cap — never up.
    private func fittedSize(_ pixel: CGSize) -> CGSize {
        guard pixel.width > 0, pixel.height > 0 else { return CGSize(width: 1, height: 1) }
        // Before the column is measured (a cached first frame), assume a phone's.
        let column = width > 0 ? width : 320
        let scale = min(1, column / pixel.width, Self.maxHeight / pixel.height)
        return CGSize(width: max(1, (pixel.width * scale).rounded(.down)),
                      height: max(1, (pixel.height * scale).rounded(.down)))
    }
}

// MARK: - Viewer presentation

/// What the full-screen viewer shows: the feed's decode first, then a sharper
/// one decoded for the screen.
struct MarkdownImageViewerInput: Identifiable {
    let id = UUID()
    let label: String
    let initial: DecodedMarkdownImage
    let target: MarkdownImageTarget
    let loader: MarkdownImageLoader
}

/// The open viewer, owned by the screen rather than the image: a row of the
/// transcript's list can be recycled — or replaced, when a streaming reply
/// settles — while its image is open, and a cover presented from it would close
/// with it.
@MainActor
@Observable
final class MarkdownImageViewerState {
    var input: MarkdownImageViewerInput?
}

private struct MarkdownImageViewerKey: EnvironmentKey {
    static let defaultValue: MarkdownImageViewerState? = nil
}

extension EnvironmentValues {
    var markdownImageViewer: MarkdownImageViewerState? {
        get { self[MarkdownImageViewerKey.self] }
        set { self[MarkdownImageViewerKey.self] = newValue }
    }
}

/// Gives the Markdown under it a loader for this transcript's images and a
/// place to open them full screen. Both are stable references, so reading them
/// never invalidates a row.
private struct MarkdownImageHost: ViewModifier {
    let client: CodegClient
    let root: String?

    @State private var slot = MarkdownImageLoaderSlot()
    @State private var viewerState = MarkdownImageViewerState()

    @ViewBuilder
    func body(content: Content) -> some View {
        @Bindable var presented = viewerState
        content
            .environment(\.markdownImageLoader, slot.loader(client: client, root: root))
            .environment(\.markdownImageViewer, viewerState)
            .fullScreenCover(item: $presented.input) { input in
                MarkdownImageViewer(input: input)
            }
    }
}

extension View {
    /// Markdown images in this transcript resolve against `root` (the
    /// conversation's folder; nil when unknown) and are read through `client`.
    func markdownImages(client: CodegClient, root: String?) -> some View {
        modifier(MarkdownImageHost(client: client, root: root))
    }
}

// MARK: - Viewer

/// Full-screen image: pinch / double-tap to zoom, drag to pan, with copy and
/// share. Dark whatever the app's appearance, like any photo viewer.
struct MarkdownImageViewer: View {
    let input: MarkdownImageViewerInput

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var sharper: DecodedMarkdownImage?
    @State private var copyTick = 0

    var body: some View {
        let image = (sharper ?? input.initial).image
        NavigationStack {
            GeometryReader { geo in
                let budget = Int(min(4096, max(geo.size.width, geo.size.height) * max(displayScale, 1)))
                ZoomableImage(image: image, label: input.label)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .task(id: budget) {
                        guard budget > 0,
                              let better = await input.loader.fullImage(for: input.target, maxPixel: budget),
                              !Task.isCancelled else { return }
                        sharper = better
                    }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(Text(verbatim: input.label))
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.image = image
                        copyTick &+= 1
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(Text("Copy image"))
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(input.label, image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("Share"))
                }
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.success, trigger: copyTick)
    }
}

/// Pinch to zoom (1×–6×), drag to pan while zoomed, double-tap to toggle.
private struct ZoomableImage: View {
    let image: UIImage
    let label: String

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(magnify.simultaneously(with: pan))
            .onTapGesture(count: 2) {
                withAnimation(Theme.Motion.chrome) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        settledScale = 2.5
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityAddTraits(.isImage)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 {
                    withAnimation(Theme.Motion.chrome) { reset() }
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: settledOffset.width + value.translation.width,
                                height: settledOffset.height + value.translation.height)
            }
            .onEnded { _ in
                settledOffset = offset
            }
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}
