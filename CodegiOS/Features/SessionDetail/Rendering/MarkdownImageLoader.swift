import SwiftUI
import UIKit
import ImageIO

/// What a Markdown image resolves to once the transcript's root is known.
enum MarkdownImageTarget: Hashable, Sendable {
    /// A file on the server: relative to the root when inside it, absolute
    /// otherwise (`MarkdownLocalImage.resolve`).
    case local(MarkdownLocalImage.Target)
    /// An `http(s)` image, fetched from this device.
    case remote(URL)

    /// The name the label falls back to when the image has no alt text.
    var name: String {
        switch self {
        case .local(let target): return target.name
        case .remote(let url): return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        }
    }

    /// SVG is not drawn yet: it shows as its label.
    var isSVG: Bool {
        switch self {
        case .local(let target): return target.mime == "image/svg+xml"
        case .remote(let url): return url.pathExtension.lowercased() == "svg"
        }
    }

    /// Where a Markdown image points, or nil when it may not be loaded: a local
    /// path that does not resolve to an image file this device may read, a
    /// destination that may have lost a separator to an escape, or a URL that
    /// is not `http(s)` (no `data:`, `file:`, `javascript:`… through here).
    static func resolve(_ image: MarkdownImageRef, root: String?) -> MarkdownImageTarget? {
        if MarkdownLocalImage.localImagePath(image.source) != nil {
            guard !image.escapeInDestination,
                  let target = MarkdownLocalImage.resolve(image.source, root: root) else { return nil }
            return .local(target)
        }
        let trimmed = image.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return .remote(url)
    }
}

/// A decoded image plus the pixel size of the file it came from (the size it
/// would draw at on the web, where an image keeps its natural size until
/// `max-width`/`max-height` bound it). `UIImage` is immutable once made, so it
/// crosses from the decoding task safely.
struct DecodedMarkdownImage: @unchecked Sendable {
    let image: UIImage
    let pixelSize: CGSize
}

/// Loads the images a transcript's Markdown points at — one per transcript
/// screen, injected through the environment by `SessionDetailView`.
///
/// Local files go through the server's own readers (inside the root:
/// `read_workspace_file_base64`, which canonicalizes and checks symlink
/// confinement; outside it: `read_file_base64`), remote ones through a
/// cookie-less ephemeral `URLSession`. Every read is capped at 8 MiB, at most
/// four run at once, and concurrent requests for the same image share one read
/// (`createLocalImageLoader` on the web).
///
/// Nothing is cached on disk, and a newly shown image is always read again —
/// the web deliberately never serves a stale screenshot after an agent rewrote
/// it. The small in-memory caches only let a view that is re-created (a row
/// recycled by the list, a reply that settles from its live form) show the
/// last image at once while the fresh read is under way, so the transcript
/// doesn't collapse to a placeholder and jump. Keys are this screen's server +
/// root + path (or the URL) — never a turn id.
final class MarkdownImageLoader: @unchecked Sendable {
    /// The transcript's folder, against which relative paths resolve. Nil when
    /// the folder is unknown: then only an absolute path names a file.
    let root: String?

    struct Readers: Sendable {
        /// `(rootPath, relativePath, maxBytes)` → base64.
        var readWorkspaceFile: @Sendable (String, String, Int) async throws -> String
        /// `(absolutePath, maxBytes)` → base64.
        var readFile: @Sendable (String, Int) async throws -> String
        /// `(url, maxBytes)` → the body, or nil past the cap / on any failure.
        var fetchRemote: @Sendable (URL, Int) async -> Data?
    }

    private let scope: String
    private let readers: Readers
    private let queue = MarkdownImageReadQueue(limit: 4)
    /// Raw bytes of the last read per key — what the full-screen viewer decodes
    /// at screen resolution without a second read.
    private let bytes = NSCache<NSString, NSData>()
    /// The last in-feed decode per key, for the instant first frame.
    private let decoded = NSCache<NSString, DecodedBox>()

    init(scope: String, root: String?, readers: Readers) {
        self.scope = scope
        self.root = (root?.isEmpty ?? true) ? nil : root
        self.readers = readers
        bytes.totalCostLimit = 32 * 1024 * 1024
        decoded.totalCostLimit = 64 * 1024 * 1024
    }

    convenience init(client: CodegClient, root: String?) {
        self.init(scope: client.baseURL.absoluteString, root: root, readers: Readers(
            readWorkspaceFile: { root, path, max in
                try await client.readWorkspaceFileBase64(rootPath: root, path: path, maxBytes: max)
            },
            readFile: { path, max in
                try await client.readFileBase64(path: path, maxBytes: max)
            },
            fetchRemote: { url, max in await MarkdownImageLoader.fetchRemote(url, maxBytes: max) }
        ))
    }

    /// The cache key: server + root + path, or the URL.
    func key(for target: MarkdownImageTarget) -> String {
        switch target {
        case .local(let t): return "local\u{1F}\(scope)\u{1F}\(root ?? "")\u{1F}\(t.path)"
        case .remote(let url): return "remote\u{1F}\(url.absoluteString)"
        }
    }

    // MARK: Reading

    /// The image as last decoded for the feed, if it is still in memory.
    func cachedImage(for target: MarkdownImageTarget) -> DecodedMarkdownImage? {
        decoded.object(forKey: key(for: target) as NSString)?.value
    }

    /// Read the image afresh and decode it to at most `maxPixel` on its long
    /// side. Nil when it cannot be read or decoded.
    func image(for target: MarkdownImageTarget, maxPixel: Int) async -> DecodedMarkdownImage? {
        let cacheKey = self.key(for: target)
        guard let data = await read(target, key: cacheKey) else { return nil }
        guard let image = await MarkdownImageLoader.decode(data, maxPixel: maxPixel) else { return nil }
        decoded.setObject(DecodedBox(image), forKey: cacheKey as NSString, cost: image.byteCost)
        return image
    }

    /// The image at a larger size for the viewer, decoded from the bytes the
    /// feed already read when they are still in memory.
    func fullImage(for target: MarkdownImageTarget, maxPixel: Int) async -> DecodedMarkdownImage? {
        let cacheKey = self.key(for: target)
        let data: Data?
        if let held = bytes.object(forKey: cacheKey as NSString) {
            data = held as Data
        } else {
            data = await read(target, key: cacheKey)
        }
        guard let data else { return nil }
        return await MarkdownImageLoader.decode(data, maxPixel: maxPixel)
    }

    private func read(_ target: MarkdownImageTarget, key: String) async -> Data? {
        let data = await queue.data(for: key) { [readers, root] in
            await MarkdownImageLoader.readBytes(target, root: root, readers: readers)
        }
        if let data {
            bytes.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        }
        return data
    }

    /// One read, with the web's bound: an absolute path through the plain file
    /// reader, a relative one inside the root (nothing without a root); an
    /// empty or over-long answer, or any error, is no image.
    static func readBytes(_ target: MarkdownImageTarget, root: String?, readers: Readers) async -> Data? {
        switch target {
        case .remote(let url):
            return await readers.fetchRemote(url, MarkdownLocalImage.maxBytes)
        case .local(let t):
            let base64: String
            do {
                if MarkdownLocalImage.isAbsoluteFilePath(t.path) {
                    base64 = try await readers.readFile(t.path, MarkdownLocalImage.maxBytes)
                } else if let root {
                    base64 = try await readers.readWorkspaceFile(root, t.path, MarkdownLocalImage.maxBytes)
                } else {
                    return nil
                }
            } catch {
                return nil
            }
            guard !base64.isEmpty, base64.utf8.count <= MarkdownLocalImage.maxBase64Length else { return nil }
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                return nil
            }
            return data
        }
    }

    // MARK: Remote

    private static let remoteSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// GET an `http(s)` image, giving up past `maxBytes` (announced or actual).
    static func fetchRemote(_ url: URL, maxBytes: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await remoteSession.bytes(for: request)
            // Leaving the loop doesn't stop the transfer: every early exit
            // (over the cap, a bad status) must cancel it, or the body keeps
            // downloading after its slot has gone to the next read.
            defer { stream.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let announced = response.expectedContentLength
            if announced > Int64(maxBytes) { return nil }
            var data = Data()
            if announced > 0 { data.reserveCapacity(Int(announced)) }
            for try await byte in stream {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: Decoding

    /// ImageIO thumbnailing: decodes straight to at most `maxPixel` on the long
    /// side (never upscaled), applying the EXIF orientation, off the main thread.
    static func decode(_ data: Data, maxPixel: Int) async -> DecodedMarkdownImage? {
        await Task.detached(priority: .userInitiated) {
            MarkdownImageLoader.downsample(data, maxPixel: maxPixel)
        }.value
    }

    static func downsample(_ data: Data, maxPixel: Int) -> DecodedMarkdownImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var pixelSize = CGSize.zero
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            // Orientations 5–8 rotate by 90°: the drawn width is the stored height.
            pixelSize = (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        if pixelSize == .zero {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        }
        return DecodedMarkdownImage(image: UIImage(cgImage: cgImage), pixelSize: pixelSize)
    }
}

private final class DecodedBox {
    let value: DecodedMarkdownImage
    init(_ value: DecodedMarkdownImage) { self.value = value }
}

private extension DecodedMarkdownImage {
    var byteCost: Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

/// Bounds reads and merges duplicates: at most `limit` in flight, a request
/// for a key already being read waits on that read instead of starting
/// another, and a finished read is forgotten at once (the next request for the
/// key reads again). A freed slot passes straight to the longest waiter.
actor MarkdownImageReadQueue {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// Requests that joined a read already in flight rather than starting one.
    private(set) var joinedReads = 0
    /// Requests waiting for a free slot.
    var waitingCount: Int { waiting.count }

    init(limit: Int) {
        self.limit = limit
    }

    func data(for key: String, read: @escaping @Sendable () async -> Data?) async -> Data? {
        if let existing = inFlight[key] {
            joinedReads += 1
            return await existing.value
        }
        let task = Task<Data?, Never> {
            await self.acquire()
            let value = await read()
            self.finish(key)
            return value
        }
        inFlight[key] = task
        return await task.value
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    private func finish(_ key: String) {
        inFlight[key] = nil
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

// MARK: - Environment

private struct MarkdownImageLoaderKey: EnvironmentKey {
    /// No loader outside a transcript (settings previews, skill bodies…): an
    /// image there shows only its label and nothing is read.
    static let defaultValue: MarkdownImageLoader? = nil
}

extension EnvironmentValues {
    var markdownImageLoader: MarkdownImageLoader? {
        get { self[MarkdownImageLoaderKey.self] }
        set { self[MarkdownImageLoaderKey.self] = newValue }
    }
}

/// Holds one transcript screen's loader across body passes, replacing it only
/// when the server or the folder changes (a draft picking its folder). A
/// plain reference held in `@State`: reading it never invalidates anything.
@MainActor
final class MarkdownImageLoaderSlot {
    private var current: MarkdownImageLoader?
    private var identity: String?

    func loader(client: CodegClient, root: String?) -> MarkdownImageLoader {
        let id = "\(client.baseURL.absoluteString)\u{1F}\(client.token)\u{1F}\(root ?? "")"
        if let current, identity == id { return current }
        let made = MarkdownImageLoader(client: client, root: root)
        current = made
        identity = id
        return made
    }
}
