import SwiftUI

/// Renders a single `ContentBlock` in isolation. The assistant transcript no
/// longer uses this directly — it is flattened into timeline nodes (`NodeBody`),
/// which pair tool calls and group runs — but the user node body still falls back
/// to it for the rare non-text/image block, so it stays a complete,
/// self-contained renderer.
struct ContentBlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .text(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownContent(raw: text)
            }
        case .thinking(let text):
            ReasoningBlock(text: text)
        case .image(let image):
            InlineImageView(image: image, caption: nil)
        case .imageGeneration(let revisedPrompt, let image):
            if let image {
                InlineImageView(image: image, caption: revisedPrompt)
            } else if let revisedPrompt {
                MarkdownContent(raw: revisedPrompt)
            }
        case .toolUse(let id, let name, let inputPreview, let status, let meta):
            ToolCallCard(vm: ToolCallVM(
                id: id ?? "tool", rawName: name, kind: "",
                // Standalone (outside a transcript) nothing vouches for the block
                // being current, so only a terminal status is read.
                state: MessageRender.toolState(paired: false, isError: false,
                                               status: status, liveness: .settled),
                input: inputPreview, output: nil, content: nil, isError: false, meta: meta))
        case .toolResult(let id, let outputPreview, let isError, let stats, _):
            ToolCallCard(vm: ToolCallVM(
                id: id ?? "result", rawName: "result", kind: "", state: isError ? .error : .done,
                input: nil, output: outputPreview, content: nil, isError: isError, agentStats: stats))
        case .turnError(let message):
            InlineTurnError(message: message, details: nil)
        case .unknown(let type):
            UnsupportedBlock(type: type)
        }
    }
}

// MARK: - Reasoning (thinking)

/// A dim "Reasoning" disclosure for `.thinking` content. Auto-expands while the
/// model is streaming its thoughts (so they're visible as they arrive) and
/// auto-collapses a beat after streaming ends; finalized reasoning starts
/// collapsed. The body renders as Markdown once finalized, verbatim while
/// streaming (to avoid re-parsing every token).
struct ReasoningBlock: View {
    let text: String
    var streaming: Bool = false

    @State private var expanded = false
    @State private var didAutoCollapse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .semibold))
                    (streaming ? Text("Thinking…") : Text("Reasoning"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    if streaming {
                        MarkdownText(raw: text, color: Theme.textSecondary, plain: true)
                    } else {
                        MarkdownContent(raw: text)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
        .onAppear { if streaming { expanded = true } }
        .onChange(of: streaming) { _, nowStreaming in
            if nowStreaming {
                expanded = true
            } else if !didAutoCollapse {
                didAutoCollapse = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.0))
                    withAnimation(.snappy(duration: 0.25)) { expanded = false }
                }
            }
        }
    }
}

// MARK: - Inline image

/// Decodes a base64 `ImageData` payload and renders it rounded, with an optional
/// caption (e.g. a revised generation prompt). The base64 → image decode runs once
/// off the main thread in a `.task` (not in `body`, where it re-ran on every
/// render — costly while the transcript invalidates during streaming) and is held
/// in a memory-pressure-evicting `NSCache`, so scrolling a decoded image back on
/// screen is free.
struct InlineImageView: View {
    let image: ImageData
    let caption: String?

    @State private var decoded: UIImage?
    @State private var failed = false

    /// Thread-safe, auto-evicting under memory pressure — the right store for a
    /// handful of potentially large transcript images.
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .hairlineBorder(Theme.Radius.md)
                    .transition(.opacity)
            } else {
                placeholder
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Theme.Motion.content, value: decoded == nil)
        .task(id: image.data) { await decode() }
    }

    /// A calm decoding box (or a decode-failure note) shown until the image lands.
    private var placeholder: some View {
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "photo")
                Text("Image could not be decoded")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, minHeight: failed ? 56 : 120)
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
    }

    private func decode() async {
        let key = image.data as NSString
        if let hit = Self.cache.object(forKey: key) { decoded = hit; failed = false; return }
        let raw = image.data
        // Heavy base64 decode off the main thread; `Data` is Sendable so it crosses
        // the boundary cleanly (UIImage(data:) defers the pixel decode to draw time).
        let data = await Task.detached(priority: .userInitiated) {
            Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
        }.value
        guard let data, let img = UIImage(data: data) else { failed = true; return }
        Self.cache.setObject(img, forKey: key)
        decoded = img
        failed = false
    }
}

// MARK: - Unknown

/// A small dim note for content variants this client version does not render.
struct UnsupportedBlock: View {
    let type: String

    var body: some View {
        Text("unsupported block: \(type)")
            .font(.mono(11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03), in: Capsule())
    }
}
