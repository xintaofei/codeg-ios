import SwiftUI

/// A horizontal strip of attached-image thumbnails shown above the compose
/// field, each with a remove button. Mirrors the web client's attachment row in
/// `ConversationContextBar`.
struct AttachmentChipsView: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) { onRemove(attachment.id) }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    private static let side: CGFloat = 56

    var body: some View {
        thumbnail
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove attachment")
            }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.kind == .file {
            ZStack {
                Color.primary.opacity(0.06)
                VStack(spacing: 2) {
                    Image(systemName: "doc")
                        .font(.system(size: 16))
                    Text(attachment.name)
                        .font(.system(size: 8))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(4)
            }
        } else if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
