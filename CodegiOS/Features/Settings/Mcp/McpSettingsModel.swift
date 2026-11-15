import SwiftUI
import Observation

/// Loads + mutates locally-installed MCP servers (`mcp_scan_local`). Add/edit go
/// through `mcp_upsert_local_server` (spec + apps together); delete is optimistic
/// with rollback. Marketplace install is deferred to a later pass.
@MainActor
@Observable
final class McpSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var servers: [LocalMcpServer] = []
    /// Agent configs the last scan couldn't read: their servers are hidden,
    /// not gone, so the list says so beside them (web `sourceUnreadable`).
    private(set) var sourceWarnings: [LocalMcpSourceWarning] = []
    var refreshError: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if servers.isEmpty { phase = .loading }
        do {
            let scan = try await client.mcpScanLocal()
            servers = scan.servers.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            sourceWarnings = scan.warnings
            phase = .loaded
            refreshError = nil
        } catch {
            // Only a screen with nothing on it shows the full-page error; a
            // list that still shows servers or warnings keeps them, with the
            // banner above.
            if servers.isEmpty, sourceWarnings.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = error.localizedDescription }
        }
    }

    func upsert(serverId: String, spec: JSONValue, apps: [McpAppType]) async throws {
        guard let client else { return }
        _ = try await client.mcpUpsertLocalServer(serverId: serverId, spec: spec, apps: apps)
        await load()
    }

    func remove(_ server: LocalMcpServer) async {
        guard let client else { return }
        let previous = servers
        servers.removeAll { $0.id == server.id }
        do {
            try await client.mcpRemoveServer(serverId: server.id)
        } catch {
            servers = previous
            refreshError = error.localizedDescription
        }
    }
}
