import Foundation

enum PrivateHost {
    /// Official Tailscale Serve / MagicDNS hosts. These are tailnet-only.
    static func needsEmbeddedTailnet(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.hasSuffix(".ts.net")
    }
}
