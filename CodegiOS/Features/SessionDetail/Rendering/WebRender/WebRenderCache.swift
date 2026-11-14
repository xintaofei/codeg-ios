import CoreGraphics
import CryptoKit
import Foundation

/// Cache keys for the off-screen web renderer. A key is what the result is a
/// function of — the source's content, the theme, and for a picture the size
/// it was drawn at — and never a turn id (codeg turn ids are only unique
/// within a conversation, so a process-wide cache keyed by one would show one
/// conversation's diagram in another). The source enters as a SHA-256 digest
/// so a key stays small however long the fence is.
enum WebRenderKey {
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whole points: a sub-point change in a column's width must not miss.
    static func points(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(value.rounded())
    }

    /// The SVG of one source in one theme — independent of where it is drawn.
    static func mermaid(source: String, theme: MermaidTheme) -> String {
        "mermaid\u{1F}\(theme.name)\u{1F}\(digest(source))"
    }

    /// The inline picture of that SVG at a column width and height cap.
    static func mermaidImage(source: String, theme: MermaidTheme, width: CGFloat, clip: CGFloat) -> String {
        "\(mermaid(source: source, theme: theme))\u{1F}w\(points(width))\u{1F}c\(points(clip))"
    }

    /// An HTML fence's document in one theme (its scheme and accent).
    static func htmlDocument(source: String, theme: ChatHtmlTheme) -> String {
        "html\u{1F}\(theme.key)\u{1F}\(digest(source))"
    }

    /// The preview of that document laid out at a column width, covering its
    /// first `clip` points.
    static func html(source: String, theme: ChatHtmlTheme, width: CGFloat, clip: CGFloat) -> String {
        "\(htmlDocument(source: source, theme: theme))\u{1F}w\(points(width))\u{1F}c\(points(clip))"
    }
}

/// A small LRU for text results, bounded by entry count and by the bytes the
/// strings hold (the web's frame cache: 32 entries / 8 MB). Main-actor only.
@MainActor
final class TextResultCache<Value> {
    private struct Entry {
        let value: Value
        let bytes: Int
    }

    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private(set) var totalBytes = 0
    let limit: Int
    let maxBytes: Int
    private let size: (Value) -> Int

    init(limit: Int, maxBytes: Int, size: @escaping (Value) -> Int) {
        self.limit = limit
        self.maxBytes = maxBytes
        self.size = size
    }

    var count: Int { entries.count }

    subscript(key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    func insert(_ value: Value, for key: String) {
        remove(key)
        // UTF-16, as the web counts: two bytes a code unit, plus the key.
        let bytes = 128 + key.utf8.count * 2 + size(value)
        entries[key] = Entry(value: value, bytes: bytes)
        order.append(key)
        totalBytes += bytes
        while (entries.count > limit || totalBytes > maxBytes), let oldest = order.first, oldest != key {
            remove(oldest)
        }
    }

    func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        order.removeAll { $0 == key }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
    }

    private func touch(_ key: String) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}
