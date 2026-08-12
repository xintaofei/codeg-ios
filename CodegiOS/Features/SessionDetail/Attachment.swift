import SwiftUI
import UniformTypeIdentifiers

/// An image the user has attached to the next prompt. Image-only: the "+" menu
/// offers no arbitrary-file route (the web client's inline file badges have no
/// counterpart here). Holds the already-prepared (downscaled/compressed) bytes so
/// the chip thumbnail and the wire payload come from the same source.
struct Attachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let mimeType: String
    let data: Data

    init(id: UUID = UUID(), name: String, mimeType: String, data: Data) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    var byteCount: Int { data.count }
    var base64: String { data.base64EncodedString() }

    /// The wire block sent in `acp_prompt`, in the encoding `caps` says the
    /// connected agent takes — a port of the web client's
    /// `imageAttachmentToPromptBlock`, with the backend's `reencode_images` rule
    /// for the case the web helper never has to face:
    ///
    /// - accepts images → a native `image` block.
    /// - rejects images but takes embedded context (Grok) → a `resource` whose
    ///   `blob` carries the same bytes under the same image mime type.
    /// - **neither**, or not yet known → a native `image` block. There is no
    ///   third shape, so re-encoding into one the agent also rejects would only
    ///   obscure the error it is about to raise; and an unknown capability must
    ///   not silently downgrade an agent that does take images.
    func promptInputBlock(for caps: PromptCapabilities?) -> PromptInputBlock {
        guard let caps, !caps.image, caps.embeddedContext else {
            return .image(data: base64, mimeType: mimeType, uri: nil)
        }
        return .resource(uri: embeddedResourceURI, mimeType: mimeType, text: nil, blob: base64)
    }

    /// Stable identifier for these bytes when they ride as an embedded resource.
    /// Every attachment here is picked/captured on the device, so there is never
    /// a path the agent could read — the uri exists only to name the blob, and is
    /// derived from the attachment (not a fresh UUID) so encoding is pure.
    /// Mirrors the web client's `clipboard://` scheme.
    private var embeddedResourceURI: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = "\(label.isEmpty ? "clipboard-image" : label)-\(id.uuidString)"
        // `encodeURIComponent`'s unreserved set, so the uri matches what the web
        // client would have produced for the same label.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return "clipboard://\(raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? id.uuidString)"
    }

    /// The block used to render this image immediately in the optimistic user
    /// turn (decoded by `InlineImageView`).
    var optimisticBlock: ContentBlock {
        .image(ImageData(data: base64, mimeType: mimeType, uri: nil))
    }
}

/// Prepares picked/captured images into compact `Attachment`s: downscales to a
/// sane max dimension and re-encodes large images as JPEG so a full-res photo
/// doesn't become a multi-megabyte base64 blob on the wire.
enum AttachmentPrep {
    static let maxDimension: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.75
    /// Hard cap on a single prepared image (sanity bound; the aggregate budget
    /// below is the binding limit in practice).
    static let maxBytes = 4 * 1024 * 1024
    /// Aggregate cap on the RAW bytes of all staged images. `acp_prompt` rides
    /// Axum's default 2 MiB JSON body limit, and base64 inflates by ~33%, so the
    /// combined payload (base64 + text + JSON overhead) must stay well under
    /// 2 MiB. ~1.3 MB raw → ~1.73 MB base64, leaving comfortable headroom.
    static let maxTotalBytes = 1_300_000
    /// Max simultaneous attachments on one prompt (secondary to the byte budget).
    static let maxCount = 10

    /// Prepare an in-memory image (camera capture or Photos pick) as a
    /// downscaled JPEG attachment.
    static func make(from image: UIImage, name: String) -> Attachment? {
        let scaled = downscaled(image, maxDimension: maxDimension)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality), !data.isEmpty else { return nil }
        guard data.count <= maxBytes else { return nil }
        return Attachment(name: name.isEmpty ? defaultName : name, mimeType: "image/jpeg", data: data)
    }

    /// Prepare image bytes (e.g. from `PhotosPickerItem.loadTransferable`).
    /// Returns nil if the bytes aren't a decodable image.
    static func make(fromImageData raw: Data, name: String) -> Attachment? {
        guard let image = UIImage(data: raw) else { return nil }
        // Re-encode through `make(from:)` when oversized or large; otherwise keep
        // the original bytes (preserves PNG transparency, avoids needless recompress)
        // — but ONLY for formats we can positively identify as agent-safe. Anything
        // unrecognized (HEIC/TIFF/…) is re-encoded to JPEG so we never ship bytes
        // under a mislabeled mime type.
        if raw.count > maxBytes || max(image.size.width, image.size.height) > maxDimension {
            return make(from: image, name: name)
        }
        guard let mime = raw.imageMimeType else {
            return make(from: image, name: name)
        }
        return Attachment(name: name.isEmpty ? defaultName : name, mimeType: mime, data: raw)
    }

    /// Prepare an image file chosen via `.fileImporter` (security-scoped URL).
    static func make(fromFile url: URL) -> Attachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let name = url.lastPathComponent
        // Files are filtered to images by the picker, but guard anyway.
        guard UIImage(data: raw) != nil else { return nil }
        return make(fromImageData: raw, name: name)
    }

    private static let defaultName = "image"

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private extension Data {
    /// Sniff a common image mime type from the file's magic bytes. Operates on a
    /// zero-based byte copy so it's safe regardless of the `Data`'s start index.
    var imageMimeType: String? {
        let bytes = Array(prefix(12))
        guard let first = bytes.first else { return nil }
        switch first {
        case 0x89: return "image/png"
        case 0xFF: return "image/jpeg"
        case 0x47: return "image/gif"
        case 0x52: // "RIFF…WEBP"
            return bytes.count >= 12 && bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) ? "image/webp" : nil
        default: return nil
        }
    }
}
