import SwiftUI
import Observation
import ImageIO

/// Display metadata for the agents this build has no compile-time knowledge of
/// — ``AgentType/other(wire:)``, in practice a user-registered ACP agent
/// (`custom:<registry-id>`, codeg ≥0.22.0).
///
/// Built-ins need nothing from here: their names are hardcoded and their brand
/// marks are compiled vector assets. A custom agent's name and icon exist only
/// on the server (`acp_list_agents` → `name` / `iconUrl`), yet they have to be
/// renderable from leaf views that are handed nothing but an `AgentType` — a
/// session row's avatar, a timeline gutter marker, a delegation card. Hence a
/// process-level cache rather than an environment value threaded through a
/// dozen call sites.
///
/// Scoped to the selected server: a custom agent registered on one server does
/// not exist on another, so the cache is keyed by endpoint and refetched when it
/// changes (see ``refreshIfNeeded(client:)``).
@MainActor
@Observable
final class CustomAgentRegistry {
    static let shared = CustomAgentRegistry()

    struct Entry: Sendable {
        /// The server's own display name (`AcpAgentInfo.name`).
        let name: String
        /// Decoded brand mark, when the server's `iconUrl` was a raster `data:`
        /// URL. Nil for the common SVG case — see ``decodeIcon(_:)``.
        let icon: UIImage?
    }

    /// Keyed by ``AgentType/rawValue`` (the full wire string, e.g.
    /// `custom:goose`).
    private(set) var entries: [String: Entry] = [:]

    /// Endpoint the cache currently describes, so a server switch drops the
    /// previous server's agent names instead of showing them.
    private var currentEndpoint: String?
    /// Endpoint whose agent list was fetched SUCCESSFULLY. Tracked separately
    /// from `entries`: the overwhelmingly common server has no custom agents at
    /// all, so a fetch that worked perfectly still leaves `entries` empty.
    private var loadedEndpoint: String?
    private var inFlight = false

    private init() {}

    // MARK: - Lookup

    /// The server's display name for a custom agent; nil for built-ins and for
    /// an agent not (yet) in the cache. Callers fall back to
    /// ``AgentType/displayName``.
    func name(for agent: AgentType) -> String? {
        guard !agent.isBuiltin else { return nil }
        return entries[agent.rawValue]?.name
    }

    /// The server's brand mark for a custom agent, when it was decodable.
    func icon(for agent: AgentType) -> UIImage? {
        guard !agent.isBuiltin else { return nil }
        return entries[agent.rawValue]?.icon
    }

    /// The best available label: the server's name, else the humanized slug.
    func label(for agent: AgentType) -> String {
        name(for: agent) ?? agent.displayName
    }

    // MARK: - Population

    /// Fill the cache from an agent list that was fetched for another reason
    /// (the Agents / Skills settings pages, the draft composer's agent picker).
    /// Free — no extra request.
    func ingest(_ agents: [AcpAgentInfo]) {
        for agent in agents where !agent.agentType.isBuiltin {
            let wire = agent.agentType.rawValue
            // Reuse an already-decoded image when the icon string is unchanged;
            // decoding runs on every list refresh otherwise.
            if let existing = entries[wire], existing.name == agent.name, existing.icon != nil {
                continue
            }
            entries[wire] = Entry(name: agent.name, icon: Self.decodeIcon(agent.iconUrl))
        }
    }

    /// Fetch the agent list once per endpoint. Called from the app-wide activity
    /// pulse so a custom agent's name/icon is available on the very first Chats
    /// render, before any settings screen has been opened.
    func refreshIfNeeded(client: CodegClient?) async {
        guard let client else {
            reset()
            return
        }
        let endpoint = "\(client.baseURL.absoluteString)|\(client.token)"
        if endpoint != currentEndpoint {
            currentEndpoint = endpoint
            entries = [:]
            loadedEndpoint = nil
        }
        // Keying this on `entries.isEmpty` instead would re-request on EVERY
        // activity pulse, forever, for every server that has no custom agents —
        // i.e. almost all of them.
        guard loadedEndpoint != endpoint, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        // A failure just leaves the cache empty and unmarked, so the next pulse
        // retries. Every consumer already falls back to the humanized slug, so
        // this must never surface an error.
        guard let agents = try? await client.listAgents() else { return }
        guard endpoint == currentEndpoint else { return }
        ingest(agents)
        loadedEndpoint = endpoint
    }

    /// Drop everything (server switch / sign-out).
    func reset() {
        entries = [:]
        currentEndpoint = nil
        loadedEndpoint = nil
    }

    // MARK: - Icon decoding

    /// Decode the server's `iconUrl` into an image, or nil when it isn't
    /// something UIKit can rasterize.
    ///
    /// The server normally inlines the ACP registry's mark as
    /// `data:image/svg+xml;base64,…`, and **UIKit has no runtime SVG decoder** —
    /// vector assets only enter through the compiled asset catalog (which is how
    /// the twelve built-in marks ship). Those fall through to the tinted
    /// monogram in ``AgentIcon``. A manually-registered agent whose icon was
    /// uploaded as PNG/JPEG decodes here and renders for real.
    ///
    /// A plain `https://` icon URL is also accepted by the server; it is NOT
    /// fetched here — a list of avatars must not fan out network requests, and
    /// those URLs are SVG in practice too.
    static func decodeIcon(_ iconUrl: String?) -> UIImage? {
        guard let raw = iconUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("data:"),
              let comma = raw.firstIndex(of: ","),
              raw[raw.startIndex..<comma].contains(";base64")
        else { return nil }
        let header = raw[raw.startIndex..<comma].lowercased()
        guard !header.contains("svg") else { return nil }
        let encoded = String(raw[raw.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return nil }
        return rasterize(data)
    }

    /// Widest icon we keep in memory. Avatars top out around 44pt @3x, so a
    /// 256px thumbnail is already generous.
    private static let iconMaxPixelSize = 256
    /// Refuse to decode anything larger. No brand mark is remotely this big; the
    /// cap exists so a decode is bounded, not to accommodate a real icon.
    private static let iconMaxPixels = 2048 * 2048

    /// Decode with an explicit pixel budget.
    ///
    /// `UIImage(data:)` would expand a small, highly-compressed PNG into an
    /// arbitrarily large bitmap: the server caps the data URL's *transfer* size,
    /// which says nothing about the decompressed dimensions, and this runs on the
    /// main actor. So read the header first — `CGImageSourceCopyPropertiesAtIndex`
    /// parses metadata without decoding pixels — reject absurd dimensions, and
    /// then let ImageIO produce a thumbnail so the resident bitmap is bounded
    /// regardless of the source.
    private static func rasterize(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= iconMaxPixels
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: iconMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
